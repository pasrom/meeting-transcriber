@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// Records microphone audio to a WAV file via AVAudioEngine.
/// Monitors for device changes via CoreAudio property listener (default input device)
/// and AVAudioEngine configuration change notification (format/route changes).
/// Automatically restarts the engine on device switch, preserving the selected device
/// when still available or falling back to system default with a warning.
///
/// Public API (`start`/`stop`/`currentLevelDBFS`) is called from the main actor.
///
/// Mutable state is split by owner. `session`, `configChangeObserver` and the
/// retry counter are confined to the main queue: a restart attempt runs on
/// `restartQueue`, builds a candidate session from locals, and publishes nothing
/// until the main queue adopts it with the arbiter's approval, so a stop and an
/// adoption are totally ordered rather than racing. `outputFile` is created in
/// `startEngine` on whichever queue runs it (main at first start, `restartQueue`
/// during an attempt) and only when the arbiter's `mayCreateOutputFile` allows
/// it under the lock; it is nilled only on the main queue, by stop and by
/// give-up. The render-thread tap block reads it through optional chaining
/// behind an `isCapturing` check, so a buffer arriving after a seal is a dropped
/// write rather than a write to a closed file. Per-buffer level state is guarded
/// by `LevelPublisher`. `@unchecked Sendable` reflects that this discipline
/// isn't expressible to the compiler.
public class MicCaptureHandler: @unchecked Sendable {
    /// Builds a fresh engine session. Injectable so tests can supply one that
    /// never touches audio hardware (the CI runner has no input device) and can
    /// be made to block on demand, which is how the issue #588 wedge is
    /// exercised without a Bluetooth headset.
    let sessionFactory: () -> MicEngineSessionProviding
    var session: MicEngineSessionProviding
    /// `internal` (not `private`) so the cross-file `+Timeline` extension can
    /// write gap-fill silence to it.
    var outputFile: AVAudioFile?
    private let outputURL: URL
    private let debugLogging: Bool
    private let liveSink: LiveAudioSink?
    // Debug fault injection (issue #379 repro): nil in production. An e2e
    // build's composition root injects one (DualSourceRecorder, gated by
    // #if E2E_FAULT_INJECTION) to verify the installTap NSException recovery.
    private let debugFault: DebugTapFault?
    /// Bounds a single restart attempt and decides what a late or superseded
    /// attempt is allowed to do (issue #588). Lock-guarded because the watchdog
    /// fires on main while the attempt runs on `restartQueue`, and the render
    /// thread reads the capture state per buffer.
    let arbiter = OSAllocatedUnfairLock(initialState: RestartArbiter())

    /// Restart attempts run here, never on the main queue: the call that brings
    /// an engine up can block forever, and on the main queue that takes the whole
    /// app down with it rather than just the microphone track.
    let restartQueue = DispatchQueue(
        label: "com.meetingtranscriber.audiotap.mic-restart",
        qos: .userInitiated,
    )

    /// Called when the microphone track was abandoned, either because a restart
    /// attempt exceeded its deadline or because the retry budget ran out. The
    /// rest of the session keeps recording.
    public var onGiveUp: (() -> Void)?

    var isRecording: Bool {
        arbiter.withLock { $0.isCapturing }
    }

    // Bounded retry for transient restart failures (issue #379): a device
    // change can briefly expose an invalid format; retry with exponential
    // backoff (MicRestartRetryPolicy) rather than dropping the recording.
    // Reset to 0 on a successful (re)start.
    var restartRetryCount = 0
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    var configChangeObserver: NSObjectProtocol?
    var selectedDeviceUID: String?
    /// Wall-clock anchoring so a device-restart gap becomes silence in the WAV
    /// instead of an under-run (issue #379 follow-up — see `+Timeline`).
    /// `internal` for that cross-file extension; survives restarts (never reset).
    var timelineAnchor = TimelineAnchor(rate: Int(speechSampleRate))
    public private(set) var firstFrameTime: UInt64 = 0

    // State for an injected DebugTapFault (above). Always compiled but inert
    // unless a fault was injected — see resolveTapInstallFormat /
    // armDebugFaultIfNeeded.
    private var debugFaultArmed = false
    private var injectBadTapFormatOnce = false

    private var debugRMS = DebugRMSReporter()
    private let levelPublisher = LevelPublisher()

    /// Returns the instantaneous mic level in dBFS, decayed to -120 if no buffer
    /// arrived in the last 0.5 seconds (e.g. device muted or unplugged) — without
    /// that, a stale reading would look like live audio.
    public var currentLevelDBFS: Double {
        levelPublisher.currentLevelDBFS
    }

    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    public convenience init(
        outputURL: URL,
        debugLogging: Bool = false,
        liveSink: LiveAudioSink? = nil,
        debugFault: DebugTapFault? = nil,
        removeInputTap: @escaping (AVAudioEngine) -> Void = { $0.inputNode.removeTap(onBus: 0) },
    ) {
        let factory: () -> MicEngineSessionProviding = {
            MicEngineSession(removeInputTap: removeInputTap)
        }
        self.init(
            outputURL: outputURL,
            debugLogging: debugLogging,
            liveSink: liveSink,
            debugFault: debugFault,
            sessionFactory: factory,
        )
    }

    /// Test seam. Deliberately not `public`: `MicEngineSessionProviding` stays
    /// internal, so the published API keeps exposing only the real engine path
    /// while same-module tests can substitute a session that never touches audio
    /// hardware.
    init(
        outputURL: URL,
        debugLogging: Bool = false,
        liveSink: LiveAudioSink? = nil,
        debugFault: DebugTapFault? = nil,
        sessionFactory: @escaping () -> MicEngineSessionProviding,
    ) {
        self.outputURL = outputURL
        self.debugLogging = debugLogging
        self.liveSink = liveSink
        self.debugFault = debugFault
        self.sessionFactory = sessionFactory
        session = sessionFactory()
    }

    deinit {
        stop()
    }

    public func start(deviceUID: String? = nil) throws {
        selectedDeviceUID = deviceUID
        try startEngine(deviceUID: deviceUID, on: session)
        _ = arbiter.withLock { $0.handle(.startSucceeded) }
        installDeviceChangeListener()
        installConfigChangeObserver()
    }

    /// Validate the live hardware format and derive a tap format that MATCHES
    /// the node's actual channel count. Issue #379: a device change to a
    /// multi-channel input (e.g. 24 kHz/1ch → 44.1 kHz/2ch) crashed because the
    /// tap was hardcoded to 1 channel — installTapOnBus raises an NSException
    /// when the tap format's channel count differs from the freshly-negotiated
    /// node bus. Matching the node's channel count and downmixing to mono in
    /// the converter (see startEngine) avoids the mismatch at the source. The
    /// 0 Hz / 0-channel guard covers the transient where the device hasn't
    /// finished re-initialising; throwing lets the restart attempt retry.
    private func validatedTapFormat(for hwFormat: AVAudioFormat) throws -> AVAudioFormat {
        guard let tapFormat = TapFormatResolver.tapFormat(forHardware: hwFormat) else {
            throw MicCaptureError.invalidHardwareFormat(
                sampleRate: hwFormat.sampleRate, channelCount: hwFormat.channelCount,
            )
        }
        return tapFormat
    }

    // swiftlint:disable function_body_length
    @discardableResult
    func startEngine(deviceUID: String?, on session: MicEngineSessionProviding) throws -> Double {
        // The one call in here that can block forever (issue #588).
        let hwFormat = try session.hardwareFormat(deviceUID: deviceUID)
        logger.info("Mic hardware format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount)ch")

        let tapFormat = try validatedTapFormat(for: hwFormat)

        if debugLogging {
            let inUID = getDefaultInputDeviceUID() ?? "?"
            let inName = getDefaultInputDeviceName() ?? "?"
            logger.info(
                "[debug] Mic input device: name=\(inName, privacy: .public) uid=\(inUID, privacy: .public) hwRate=\(hwFormat.sampleRate, privacy: .public) hwChannels=\(hwFormat.channelCount, privacy: .public)",
            )
        }

        logger.info("Mic tap format: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount)ch")

        // Always 16kHz — WhisperKit target rate. `mayCreateOutputFile` is false
        // once the session was sealed by a give-up or a stop: a wedged attempt
        // that returns later must not recreate (and thereby truncate) a
        // recording that was already finalized.
        // Always the speech rate; it was a stored property whose only value was
        // this constant, which made it look like per-session state.
        let fileSampleRate = speechSampleRate
        if outputFile == nil, arbiter.withLock({ $0.mayCreateOutputFile }) {
            let wavSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: fileSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            outputFile = try AVAudioFile(forWriting: outputURL, settings: wavSettings)
            // Restrict permissions to owner-only (0600) — audio may contain sensitive meeting content
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path,
            )
            // A fresh file gets a fresh wall-clock anchor — its accounting
            // belongs to this file's sample stream. Restarts keep the file
            // (and the anchor), so a restart gap is bridged with silence.
            timelineAnchor = TimelineAnchor(rate: Int(fileSampleRate))
        }

        // Locals, captured by value below. Sharing them across sessions loses
        // audio silently: a restart attempt rebuilds them for ITS format before
        // the arbiter has agreed to adopt it, while the previous session's tap
        // block is still installed and still delivering buffers in the old one.
        // Those buffers then go through a converter that does not match them and
        // are dropped without an error (issue #589).
        let resampleRatio = fileSampleRate / tapFormat.sampleRate
        var converter: AVAudioConverter?
        if let setup = MicConverterFactory.make(tapFormat: tapFormat, fileSampleRate: fileSampleRate) {
            converter = setup.converter
            if let channel = setup.selectedChannel {
                logger.info(
                    "Mic: layout has no usable implicit downmix — selecting channel \(channel) explicitly",
                )
            }
            logger.info(
                "Mic: converting \(Int(tapFormat.sampleRate))Hz/\(tapFormat.channelCount)ch → \(Int(fileSampleRate))Hz/1ch",
            )
        }

        // Normally returns tapFormat unchanged; under an injected DebugTapFault
        // it returns an invalid format once to exercise the recovery path.
        let installFormat = resolveTapInstallFormat(default: tapFormat)
        // installTapOnBus raises an ObjC NSException for an invalid/incompatible
        // format (issue #379); Swift can't catch that. Build the tap block, then
        // install it through the ObjC shim so a raise becomes a recoverable throw.
        // swiftlint:disable closure_parameter_position closure_body_length
        let tapBlock: AVAudioNodeTapBlock = {
            [weak self] buffer, when in
            // swiftlint:enable closure_parameter_position closure_body_length
            guard let self, self.isRecording else { return }
            if self.firstFrameTime == 0 {
                self.firstFrameTime = mach_absolute_time()
            }
            self.accumulateDebugRMS(buffer: buffer)
            self.publishCurrentLevel()
            self.maybeReportDebugRMS()
            do {
                if let converter {
                    let outputFrames = resampleOutputCapacity(
                        inputFrames: buffer.frameLength, ratio: resampleRatio,
                    )
                    guard let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: converter.outputFormat,
                        frameCapacity: outputFrames,
                    ) else { return }
                    var error: NSError?
                    let feed = FeedOnce(buffer: buffer)
                    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                        feed.next(outStatus)
                    }
                    if let error {
                        logger.warning("Mic resample error: \(error.localizedDescription, privacy: .public)")
                    } else {
                        self.fillTimelineGap(before: when, outputFrames: Int(outputBuffer.frameLength))
                        try self.outputFile?.write(from: outputBuffer)
                        self.forwardToLiveSink(buffer: outputBuffer)
                    }
                } else {
                    self.fillTimelineGap(before: when, outputFrames: Int(buffer.frameLength))
                    try self.outputFile?.write(from: buffer)
                    self.forwardToLiveSink(buffer: buffer)
                }
            } catch {
                logger.warning("Mic write error: \(error.localizedDescription, privacy: .public)")
            }
        }

        try session.installTap(format: installFormat, block: tapBlock)
        try session.start()
        logger.info("Mic recording started: \(self.outputURL.lastPathComponent)")

        armDebugFaultIfNeeded()
        return hwFormat.sampleRate
    }

    // swiftlint:enable function_body_length

    private func installDeviceChangeListener() {
        guard deviceChangeListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputDeviceChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            listener,
        )
        if status == noErr {
            deviceChangeListener = listener
            logger.info("Mic: listening for default input device changes")
        } else {
            logger.warning("Failed to install device change listener (status: \(status))")
        }
    }

    /// Listen for AVAudioEngine configuration changes (format changes on current device).
    func installConfigChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: session.notificationObject,
            queue: .main,
        ) { [weak self] _ in
            self?.handleEngineConfigChange()
        }
        logger.info("Mic: listening for engine configuration changes")
    }

    private func handleEngineConfigChange() {
        logger.info("Mic: engine configuration changed (format/route change)")
        handleDeviceChange()
    }

    private func handleDefaultInputDeviceChanged() {
        logger.info("Mic: default input device changed")
        handleDeviceChange()
    }

    public func stop() {
        // Seal first, so any in-flight tap closure short-circuits before touching
        // the soon-released AVAudioFile. The arbiter also answers the question
        // that decides the rest of this method: is a restart attempt currently
        // inside the engine? If so, every engine call below would block behind
        // the mutex that attempt holds, and stopping a recording would freeze the
        // caller (issue #588).
        let decision = arbiter.withLock { $0.handle(.stopRequested) }
        if let listener = deviceChangeListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                listener,
            )
            deviceChangeListener = nil
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        // Tap removal, stop/reset and the retain-grace that keeps in-flight
        // AVFoundation listener blocks firing against a live object all live in
        // the session now, including the "no tap was installed" guard that keeps
        // an input-less host from raising in the deinit path.
        //
        // Skipped entirely when an attempt is stuck inside the engine: the
        // attempt's own stale-commit path tears down what it built, and the
        // engine it is wedged in is unreachable either way.
        switch decision {
        case .teardown:
            session.teardown()

        case .sealAndSkipEngine:
            logger.warning("Mic: stopping while a restart attempt is outstanding — leaving its engine alone")

        default:
            // Already stopped. Nothing to release, and touching the engine again
            // would be a double teardown via deinit.
            break
        }
        outputFile = nil
        logger.info("Mic recording stopped")
    }
}

// MARK: - Debug logging helpers

extension MicCaptureHandler {
    /// Publish the most recent per-buffer dBFS reading so UI consumers
    /// (menu bar level indicator) can poll it. Called from the
    /// AVAudioEngine tap callback after `accumulateDebugRMS`.
    func publishCurrentLevel() {
        levelPublisher.publish(level: debugRMS.lastLevelDBFS)
    }

    /// Sum squares across all channels of an AVAudioPCMBuffer into the shared
    /// reporter. AVAudioEngine taps deliver float buffers in practice; the int16
    /// branch is a safety net.
    func accumulateDebugRMS(buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        let sumSq: Double
        if let floatData = buffer.floatChannelData {
            sumSq = sumOfSquaresFloat(floatData, frames: frames, channels: channelCount)
        } else if let int16Data = buffer.int16ChannelData {
            sumSq = sumOfSquaresInt16(int16Data, frames: frames, channels: channelCount)
        } else {
            return
        }
        debugRMS.add(sumSq: sumSq, samples: frames * channelCount)
    }

    /// Drain the 5-s throttle and emit one RMS-energy log line per tick, but
    /// only when `debugLogging` is on. The drain itself runs unconditionally
    /// so the reporter's accumulators stay bounded for long sessions.
    func maybeReportDebugRMS() {
        guard let report = debugRMS.tick() else { return }
        guard debugLogging else { return }
        let dBStr = String(format: "%.1f", report.dBFS)
        logger.info(
            "[debug] Mic RMS (5s): \(dBStr, privacy: .public) dBFS, samples=\(report.samples, privacy: .public)",
        )
    }

    /// Hand the freshly-written PCM buffer (mono Float32 at file rate, typically
    /// 16 kHz post-resample) to the optional live sink. Short-circuits when no
    /// sink is installed.
    func forwardToLiveSink(buffer: AVAudioPCMBuffer) {
        guard let sink = liveSink else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else { return }
        let ptr = channelData[0]
        let samples = Array(UnsafeBufferPointer(start: ptr, count: frames))
        sink(LiveAudioBuffer(
            samples: samples,
            channelCount: Int(buffer.format.channelCount),
            sampleRate: Int(buffer.format.sampleRate),
            hostTime: mach_absolute_time(),
        ))
    }
}

private func sumOfSquaresFloat(
    _ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int, channels: Int,
) -> Double {
    var sumSq: Double = 0
    for ch in 0 ..< channels {
        let ptr = data[ch]
        for i in 0 ..< frames {
            sumSq += Double(ptr[i]) * Double(ptr[i])
        }
    }
    return sumSq
}

private func sumOfSquaresInt16(
    _ data: UnsafePointer<UnsafeMutablePointer<Int16>>, frames: Int, channels: Int,
) -> Double {
    let scale = 1.0 / 32768.0
    var sumSq: Double = 0
    for ch in 0 ..< channels {
        let ptr = data[ch]
        for i in 0 ..< frames {
            let s = Double(ptr[i]) * scale
            sumSq += s * s
        }
    }
    return sumSq
}

public enum MicCaptureError: LocalizedError {
    case noInputDevice
    case invalidHardwareFormat(sampleRate: Double, channelCount: UInt32)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone hardware available"

        case let .invalidHardwareFormat(sampleRate, channelCount):
            "Microphone reported an invalid format (\(sampleRate) Hz, \(channelCount) ch)"
        }
    }
}

// MARK: - Debug fault injection (issue #379 recovery verification)

private extension MicCaptureHandler {
    /// In production (`debugFault == nil`) returns `real` unchanged. Under an
    /// injected fault it returns an invalid (0 Hz) tap format exactly once —
    /// the condition that makes installTapOnBus raise
    /// `IsFormatSampleRateAndChannelCountValid` — so the e2e can verify the
    /// NSException recovery path end-to-end.
    func resolveTapInstallFormat(default real: AVAudioFormat) -> AVAudioFormat {
        guard injectBadTapFormatOnce else { return real }
        injectBadTapFormatOnce = false
        guard let bad = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false,
        ) else { return real }
        logger.warning("[debug-fault] installing invalid (0 Hz) tap format (issue #379 repro)")
        return bad
    }

    /// No-op in production. When a `DebugTapFault` was injected: once, after the
    /// first successful start, schedule a single self-triggered device-change
    /// restart whose tap install uses the bad format. Drives the real
    /// handleDeviceChange -> launchRestartAttempt -> startEngine path so the
    /// reproduction exercises production code, not a shortcut.
    func armDebugFaultIfNeeded() {
        guard let debugFault, !debugFaultArmed else { return }
        debugFaultArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + debugFault.triggerRestartAfter) { [weak self] in
            guard let self, self.isRecording else { return }
            logger.warning("[debug-fault] firing simulated mic device-change mid-recording (issue #379 repro)")
            self.injectBadTapFormatOnce = true
            self.handleDeviceChange()
        }
    }
}
