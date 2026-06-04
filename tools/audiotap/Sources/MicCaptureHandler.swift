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
/// The `installTap` render-thread callback writes to per-buffer state guarded by
/// `LevelPublisher` (lock-protected) and to `outputFile` which is only mutated
/// between `engine.stop()` and `engine.start()` on the main thread, so concurrent
/// IO with the render thread is impossible by lifecycle. `@unchecked Sendable`
/// reflects that this discipline isn't expressible to the compiler.
public class MicCaptureHandler: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private let outputURL: URL
    private let debugLogging: Bool
    private let liveSink: LiveAudioSink?
    // Debug fault injection (issue #379 repro): nil in production. An e2e
    // build's composition root injects one (DualSourceRecorder, gated by
    // #if E2E_FAULT_INJECTION) to verify the installTap NSException recovery.
    private let debugFault: DebugTapFault?
    private var isRecording = false
    private var isRestarting = false
    // Bounded retry for transient restart failures (issue #379): a device
    // change can briefly expose an invalid format; retry with exponential
    // backoff (MicRestartRetryPolicy) rather than dropping the recording.
    // Reset to 0 on a successful (re)start.
    private var restartRetryCount = 0
    // True while a retry is pending in the backoff window. `isRestarting` is
    // cleared synchronously when executeRestart returns, so without this a
    // device change arriving during the 0.3 s backoff would start a second,
    // parallel restart chain racing the pending one on `engine`.
    private var retryScheduled = false
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var configChangeObserver: NSObjectProtocol?
    private var selectedDeviceUID: String?
    private var fileSampleRate: Double = 0
    private var converter: AVAudioConverter?
    /// Pre-computed resampling ratio (fileSampleRate / tapSampleRate), avoids division in audio callback.
    private var resampleRatio: Double = 1.0
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

    public init(
        outputURL: URL,
        debugLogging: Bool = false,
        liveSink: LiveAudioSink? = nil,
        debugFault: DebugTapFault? = nil,
    ) {
        self.outputURL = outputURL
        self.debugLogging = debugLogging
        self.liveSink = liveSink
        self.debugFault = debugFault
    }

    deinit {
        stop()
    }

    private static func deviceIDForUID(_ uid: String) -> AudioDeviceID {
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

    public func start(deviceUID: String? = nil) throws {
        selectedDeviceUID = deviceUID
        try startEngine(deviceUID: deviceUID)
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
    /// finished re-initialising; throwing lets executeRestart retry.
    private func validatedTapFormat(for hwFormat: AVAudioFormat) throws -> AVAudioFormat {
        guard let tapFormat = TapFormatResolver.tapFormat(forHardware: hwFormat) else {
            throw MicCaptureError.invalidHardwareFormat(
                sampleRate: hwFormat.sampleRate, channelCount: hwFormat.channelCount,
            )
        }
        return tapFormat
    }

    // swiftlint:disable:next function_body_length
    private func startEngine(deviceUID: String? = nil) throws {
        // No input device available (e.g. Mac Mini server without mic hardware) —
        // accessing AVAudioEngine.inputNode would throw an uncatchable NSException.
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

        let hwFormat = inputNode.outputFormat(forBus: 0)
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

        // Always 16kHz — WhisperKit target rate
        if outputFile == nil {
            fileSampleRate = speechSampleRate
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
        }

        converter = nil
        resampleRatio = fileSampleRate / tapFormat.sampleRate
        // Convert to 16 kHz mono whenever the tap isn't already there — this
        // covers resampling AND downmixing a multi-channel input device. Since
        // the tap now matches the node's real channel count (issue #379), a
        // 2ch device is captured as 2ch and folded to the mono WAV here.
        if tapFormat.sampleRate != fileSampleRate || tapFormat.channelCount != 1 {
            let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: fileSampleRate, channels: 1,
            )! // swiftlint:disable:this force_unwrapping
            converter = AVAudioConverter(from: tapFormat, to: outputFormat)
            logger.info(
                "Mic: converting \(Int(tapFormat.sampleRate))Hz/\(tapFormat.channelCount)ch → \(Int(self.fileSampleRate))Hz/1ch",
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
            [weak self] buffer, _ in
            // swiftlint:enable closure_parameter_position closure_body_length
            guard let self, self.isRecording else { return }
            if self.firstFrameTime == 0 {
                self.firstFrameTime = mach_absolute_time()
            }
            self.accumulateDebugRMS(buffer: buffer)
            self.publishCurrentLevel()
            self.maybeReportDebugRMS()
            do {
                if let converter = self.converter {
                    let outputFrames = AVAudioFrameCount(
                        Double(buffer.frameLength) * self.resampleRatio,
                    )
                    guard let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: converter.outputFormat,
                        frameCapacity: outputFrames,
                    ) else { return }
                    var error: NSError?
                    // The converter input block is typed `@Sendable`, so a
                    // captured `var Bool` would trip Swift 6's concurrent-
                    // capture check — even though the block actually runs
                    // synchronously while `convert(to:error:withInputFrom:)`
                    // is on the stack. Box the flag so the closure captures
                    // it by-reference.
                    final class InputState: @unchecked Sendable { var consumed = false }
                    let inputState = InputState()
                    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                        if inputState.consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        inputState.consumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if let error {
                        logger.warning("Mic resample error: \(error)")
                    } else {
                        try self.outputFile?.write(from: outputBuffer)
                        self.forwardToLiveSink(buffer: outputBuffer)
                    }
                } else {
                    try self.outputFile?.write(from: buffer)
                    self.forwardToLiveSink(buffer: buffer)
                }
            } catch {
                logger.warning("Mic write error: \(error)")
            }
        }

        do {
            try inputNode.safeInstallTap(onBus: 0, bufferSize: 4096, format: installFormat, block: tapBlock)
        } catch {
            logger.error("Mic: installTap failed (\(error.localizedDescription)) — restart will retry")
            throw error
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        restartRetryCount = 0
        logger.info("Mic recording started: \(self.outputURL.lastPathComponent)")

        armDebugFaultIfNeeded()
    }

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
    private func installConfigChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
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

    private func handleDeviceChange() {
        let isDeviceAvailable = selectedDeviceUID.map { Self.deviceIDForUID($0) != kAudioObjectUnknown } ?? false
        let action = MicRestartPolicy.decideRestart(
            isRecording: isRecording,
            // Treat a pending retry as still-restarting so a device change in
            // the backoff window doesn't spawn a competing restart chain.
            isRestarting: isRestarting || retryScheduled,
            selectedDeviceUID: selectedDeviceUID,
            isSelectedDeviceAvailable: isDeviceAvailable,
        )

        switch action {
        case let .restart(deviceUID):
            executeRestart(deviceUID: deviceUID)

        case .skip:
            break
        }
    }

    private func executeRestart(deviceUID: String?) {
        isRestarting = true
        defer { isRestarting = false }

        if deviceUID == nil, let uid = selectedDeviceUID {
            logger.warning("Mic: selected device '\(uid)' no longer available, falling back to system default")
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // AVAudioEngine can be in a bad state after config change — must recreate.
        // Hold a strong reference to the old engine for a grace period so any
        // in-flight `AVAudioIOUnit::IOUnitPropertyListener` blocks that
        // AVFoundation queued on a libdispatch worker fire against a live
        // object. Without this hold, dropping the last reference here races
        // against those blocks and crashes with EXC_BAD_ACCESS in
        // `objc_msgSend` on the freed engine.
        let oldEngine = engine
        engine = AVAudioEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = oldEngine
        }

        do {
            try startEngine(deviceUID: deviceUID)
            let hwRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
            if hwRate <= 0 {
                logger.warning("Mic: hardware format rate is \(hwRate) after restart — may produce incorrect audio")
            }
            installConfigChangeObserver()
            logger.info("Mic: engine restarted on \(deviceUID != nil ? "selected" : "default") device (\(Int(hwRate)) Hz)")
        } catch {
            // A transient invalid format / installTap raise (issue #379) is
            // recoverable: the device usually settles within a few hundred ms.
            // Keep recording and retry with backoff instead of killing it.
            logger.error("Failed to restart mic after device change: \(error) — scheduling retry")
            scheduleRestartRetry(deviceUID: deviceUID)
        }
    }

    /// Re-attempt a failed restart after a short backoff, bounded by
    /// `maxRestartRetries`. Only retries while still recording; gives up (and
    /// stops recording) once the budget is exhausted.
    private func scheduleRestartRetry(deviceUID: String?) {
        guard isRecording else { return }
        switch MicRestartRetryPolicy.decide(attemptsSoFar: restartRetryCount) {
        case .giveUp:
            isRecording = false
            logger.error("Mic: giving up restart after \(MicRestartRetryPolicy.maxAttempts) failed attempts")

        case let .retry(delay):
            restartRetryCount += 1
            retryScheduled = true
            let attempt = restartRetryCount
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                guard self.isRecording else { return }
                logger.info("Mic: restart retry \(attempt)/\(MicRestartRetryPolicy.maxAttempts)")
                self.executeRestart(deviceUID: deviceUID)
            }
        }
    }

    public func stop() {
        // Set isRecording=false first so any in-flight tap closure short-circuits
        // before touching the soon-released AVAudioFile.
        isRecording = false
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        outputFile = nil

        // Mirror the retain-grace from executeRestart: if the caller drops
        // MicCaptureHandler immediately after stop() returns, the engine
        // ivar's last reference would race against any in-flight
        // AVAudioIOUnit::IOUnitPropertyListener block AVFoundation queued
        // on a libdispatch worker. Holding a local ref for 500 ms lets
        // those blocks fire against a live object.
        let retainedEngine = engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = retainedEngine
        }
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
    /// handleDeviceChange → executeRestart → startEngine path so the
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
