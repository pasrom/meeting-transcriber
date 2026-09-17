@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicEngineSession")

/// Everything in the microphone path that touches `AVAudioEngine` or CoreAudio,
/// behind a protocol so the rest of `MicCaptureHandler` can be tested without
/// audio hardware.
///
/// Two reasons this seam exists, and only the second one is about tests:
///
/// 1. A session is exactly one engine's lifetime. A restart after a device
///    change discards the old session and builds a new one, which is what the
///    code already did by replacing the `AVAudioEngine` instance; naming it
///    makes the boundary explicit.
/// 2. The bring-up calls can block forever: `hardwareFormat`, `installTap` and
///    `start`. `hardwareFormat` is the one that wedged in issue #588. On a fresh
///    engine it loops inside AVFAudio when the default-device aggregate still
///    references a Bluetooth device that just vanished, and it cannot be
///    cancelled. Isolating those calls lets a test substitute a session that
///    blocks on demand, and lets the handler reason about "an attempt may be
///    stuck in here" in one place.
///
///    `teardown` is deliberately NOT in that class, and that assumption is
///    load-bearing: it runs on the main queue, exactly as `stop()` always has,
///    against an engine whose IO unit is already built, so it does not take the
///    path that loops. If it could block forever, running it on main would
///    reintroduce the freeze this whole design exists to prevent.
///
/// The CI runner has no input device at all, so no test may ever construct a
/// real session. That is a hard constraint, not a preference: reading
/// `AVAudioEngine.inputNode` on an input-less host raises an uncatchable
/// NSException.
protocol MicEngineSessionProviding: AnyObject {
    /// The object `AVAudioEngineConfigurationChange` notifications are keyed on.
    var notificationObject: AnyObject { get }

    /// Bring the engine up far enough to report the live hardware format,
    /// pinning `deviceUID` when one is given and still present.
    ///
    /// This is the call that can wedge. Everything after it is cheap.
    func hardwareFormat(deviceUID: String?) throws -> AVAudioFormat

    /// The microphone this recording is coming from, as of the last
    /// `hardwareFormat`. Nil before then, and when no device could be
    /// identified at all.
    ///
    /// The diagnostics need it from here rather than from
    /// `kAudioHardwarePropertyDefaultInputDevice`, because a pinned device and
    /// the system default are not the same microphone and the log named the
    /// wrong one (issue #724). What it is *not* is the raw device the unit is
    /// bound to: see the implementation for why that answer is unusable when
    /// nothing is pinned.
    var boundInputDevice: MicInputDevice? { get }

    /// Attach the capture tap. Raises from AVFAudio are bridged to throws.
    func installTap(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) throws

    /// `prepare()` + `start()`.
    func start() throws

    /// Remove the tap if one was installed, stop and reset the engine.
    func teardown()
}

extension MicEngineSessionProviding {
    /// A session that does not track its device reports nothing, which the
    /// diagnostics render exactly as CoreAudio declining to answer. Only the
    /// real session can know, and only the diagnostics ask, so a fake that is
    /// about something else does not have to care.
    var boundInputDevice: MicInputDevice? {
        nil
    }
}

/// The real implementation, wrapping one `AVAudioEngine`.
final class MicEngineSession: MicEngineSessionProviding {
    private var engine = AVAudioEngine()
    private let removeInputTap: (AVAudioEngine) -> Void

    private(set) var tapInstalled = false

    /// What came of the last `hardwareFormat`'s device pin, including what the
    /// unit answered afterwards. Both the log line and `boundInputDevice` are
    /// derived from it, so they cannot disagree.
    ///
    /// The read it carries is taken eagerly, in `hardwareFormat`, even though
    /// only the diagnostics consume it. That costs one property read per engine
    /// start. Reading it inside the getter instead would have the getter reach
    /// back into the engine at a time nothing here controls, including after
    /// `teardown` has stopped and reset it, and one cheap read on a unit that
    /// is known to be up buys that question away.
    private var pinOutcome: MicDevicePinOutcome = .notRequested

    var notificationObject: AnyObject {
        engine
    }

    /// The pinned device when the pin took, the system default input otherwise.
    ///
    /// Deliberately not "whatever device the unit reports". Measured on macOS
    /// 26: with nothing pinned, `AVAudioEngine` does not bind its input unit to
    /// the microphone at all but to a private aggregate of its own, named
    /// `CADefaultDeviceAggregate-<n>-0`, which follows the system default
    /// input. Naming that aggregate answers nothing a reader can act on, and
    /// the question these diagnostics exist for is exactly "built-in or
    /// headset". So when nothing was pinned, or a pin did not take, the honest
    /// answer is the device the aggregate is following, which is what this used
    /// to report and what it still reports there.
    var boundInputDevice: MicInputDevice? {
        pinOutcome
            .deviceToReport(systemDefault: Self.systemDefaultInputDeviceID())
            .map(Self.describe)
    }

    private static func describe(_ deviceID: AudioDeviceID) -> MicInputDevice {
        MicInputDevice(
            uid: readCFStringAudioProperty(deviceID, kAudioDevicePropertyDeviceUID),
            name: readCFStringAudioProperty(deviceID, kAudioObjectPropertyName),
        )
    }

    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        guard case let .value(deviceID) = defaultDeviceReading(
            selector: kAudioHardwarePropertyDefaultInputDevice,
        ), deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    init(removeInputTap: @escaping (AVAudioEngine) -> Void = { $0.inputNode.removeTap(onBus: 0) }) {
        self.removeInputTap = removeInputTap
    }

    func hardwareFormat(deviceUID: String?) throws -> AVAudioFormat {
        // No input device at all (a Mac mini without a mic, a CI runner):
        // reading `inputNode` would raise an uncatchable NSException.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw MicCaptureError.noInputDevice
        }

        let inputNode = engine.inputNode

        pinOutcome = pin(deviceUID: deviceUID, on: inputNode)
        if let line = pinOutcome.logLine {
            // A pin that was refused, or accepted and then not adopted, means
            // the recording is running on a microphone the user did not choose.
            // That is a finding, not a note, and it used to be logged as a
            // success either way. The level comes from the outcome so the three
            // ordinary-to-serious steps stay where they are decided and tested.
            //
            // Public is safe only because `logLine` carries no device UID: this
            // line is unconditional and lands in the exported diagnostics. See
            // the note on `logLine`.
            logger.log(level: pinOutcome.level, "\(line, privacy: .public)")
        }

        return inputNode.outputFormat(forBus: 0)
    }

    /// Point the unit at the configured device, then ask the unit where it
    /// actually is. Asking is the point: `AudioUnitSetProperty` returning
    /// `noErr` says the call was accepted, not that the unit moved, and this is
    /// the one place that difference can still be seen.
    private func pin(deviceUID: String?, on inputNode: AVAudioInputNode) -> MicDevicePinOutcome {
        guard let uid = deviceUID else { return .notRequested }
        var deviceID = Self.deviceIDForUID(uid)
        guard deviceID != kAudioObjectUnknown else { return .unresolvedUID(uid) }
        let audioUnit = inputNode.audioUnit! // swiftlint:disable:this force_unwrapping
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size),
        )
        return .set(
            uid: uid, requested: deviceID, status: status,
            actual: Self.currentDeviceID(of: inputNode),
        )
    }

    /// The device the unit is currently on. Optional rather than force-unwrapped
    /// because a diagnostic must never be the thing that crashes a recording.
    private static func currentDeviceID(of inputNode: AVAudioInputNode) -> AudioDeviceID? {
        guard let audioUnit = inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &deviceID, &size,
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func installTap(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) throws {
        do {
            try engine.inputNode.safeInstallTap(onBus: 0, bufferSize: 4096, format: format, block: block)
        } catch {
            logger.error("Mic: installTap failed (\(error.localizedDescription, privacy: .public)) — restart will retry")
            throw error
        }
        // inputNode accessed and a tap attached: teardown must remove it even if
        // start() throws afterwards.
        tapInstalled = true
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func teardown() {
        // Skip the inputNode teardown when no tap was installed — the getter
        // raises an uncatchable NSException on an input-less host.
        if tapInstalled {
            removeInputTap(engine)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
        // A session is one engine's lifetime, so the device it was on stops
        // being an answer here rather than becoming a stale one.
        pinOutcome = .notRequested

        // Hold a strong reference to the engine for a grace period so any
        // in-flight `AVAudioIOUnit::IOUnitPropertyListener` blocks that
        // AVFoundation queued on a libdispatch worker fire against a live
        // object. Without this hold, dropping the last reference races those
        // blocks and crashes with EXC_BAD_ACCESS in `objc_msgSend` on the freed
        // engine.
        let retained = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = retained
        }
    }

    /// Resolve a device UID to its current `AudioDeviceID`, or
    /// `kAudioObjectUnknown` when the device is gone. Plain CoreAudio, no engine
    /// involved, so the restart policy can ask "is my device still there" without
    /// going anywhere near the calls that can wedge.
    static func deviceIDForUID(_ uid: String) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID: Unmanaged<CFString>? = Unmanaged.passUnretained(uid as CFString)
        let qualifierSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, qualifierSize, &cfUID,
            &size, &deviceID,
        )
        return deviceID
    }
}
