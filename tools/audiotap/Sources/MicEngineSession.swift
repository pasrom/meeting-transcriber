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

    /// Attach the capture tap. Raises from AVFAudio are bridged to throws.
    func installTap(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) throws

    /// `prepare()` + `start()`.
    func start() throws

    /// Remove the tap if one was installed, stop and reset the engine.
    func teardown()
}

/// The real implementation, wrapping one `AVAudioEngine`.
final class MicEngineSession: MicEngineSessionProviding {
    private var engine = AVAudioEngine()
    private let removeInputTap: (AVAudioEngine) -> Void

    private(set) var tapInstalled = false

    var notificationObject: AnyObject { engine }

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

        if let uid = deviceUID {
            var deviceID = Self.deviceIDForUID(uid)
            if deviceID != kAudioObjectUnknown {
                let audioUnit = inputNode.audioUnit! // swiftlint:disable:this force_unwrapping
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size),
                )
                logger.info("Mic device set: \(uid) (ID \(deviceID))")
            } else {
                logger.warning("Unknown mic device UID '\(uid)', using default")
            }
        }

        return inputNode.outputFormat(forBus: 0)
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
