import AppKit
import AudioTapLib

// `@preconcurrency`: AVFoundation types lack Sendable annotations —
// same gap as AudioMixer.swift; preemptively guarded.
@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "DualSourceRecorder")

/// Result of a recording session.
struct RecordingResult {
    let mixPath: URL
    let appPath: URL?
    let micPath: URL?
    let micDelay: TimeInterval
    let recordingStart: TimeInterval // ProcessInfo.systemUptime
}

/// The recorder's declared capture format, passed to `buildRecording` so the
/// processing logic stays free of instance state (and unit-testable).
/// `requested*` are what we asked the device for (used to flag a USB/Bluetooth
/// renegotiation in the logs); `targetRate` is the rate we resample/mix to.
struct CaptureFormat {
    let requestedChannels: Int
    let requestedRate: Int
    let targetRate: Int
}

/// Abstraction for recording, enabling mock injection in tests.
@MainActor
protocol RecordingProvider {
    func start(appPID: pid_t, noMic: Bool, micDeviceUID: String?, debugLogging: Bool) throws
    func stop() throws -> RecordingResult

    /// Instantaneous app-audio level in dBFS. -120 when no capture session is
    /// active or the tap stopped delivering buffers in the last 0.5 s.
    /// Drives the menu-bar asymmetric-silence indicator. Default: -120
    /// (mocks that don't simulate audio levels stay silent).
    var appLevelDBFS: Double { get }

    /// Instantaneous mic level in dBFS, with the same semantics as
    /// `appLevelDBFS`.
    var micLevelDBFS: Double { get }
}

extension RecordingProvider {
    var appLevelDBFS: Double {
        -120
    }

    var micLevelDBFS: Double {
        -120
    }
}

/// Orchestrates app audio capture (via AudioTapLib) + mic recording, then mixes.
@MainActor
@Observable
class DualSourceRecorder: RecordingProvider {
    @available(macOS 14.2, *)
    private var captureSession: AudioCaptureSession? {
        get { _captureSession as? AudioCaptureSession }
        set { _captureSession = newValue }
    }

    // Type-erased storage to avoid @available on stored properties
    private var _captureSession: AnyObject?
    private(set) var isRecording = false
    private(set) var recordingStartTime: TimeInterval = 0
    private var startTimestamp: String?

    var appLevelDBFS: Double {
        guard #available(macOS 14.2, *) else { return -120 }
        return captureSession?.appLevelDBFS ?? -120
    }

    var micLevelDBFS: Double {
        guard #available(macOS 14.2, *) else { return -120 }
        return captureSession?.micLevelDBFS ?? -120
    }

    private let recordRate = 48000
    private let targetRate = AudioConstants.targetSampleRate
    private let appChannels = 2

    /// Recordings directory.
    static var recordingsDir: URL {
        AppPaths.recordingsDir
    }

    /// Suffix on the merged-output WAV file, used by downstream code (the
    /// record-only sidecar writer) to recover the recording basename.
    static let mixFilenameSuffix = RecordingFileSuffix.mix

    /// Remove leftover `*_app_raw.tmp` files from a previous crash.
    static func cleanupTempFiles(recordingsDir: URL = AppPaths.recordingsDir) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: nil,
        ) else { return }

        for file in entries where file.lastPathComponent.hasSuffix("_app_raw.tmp") {
            try? fm.removeItem(at: file)
            logger.info("Removed orphaned temp file: \(file.lastPathComponent)")
        }
    }

    /// Optional live-buffer sinks installed by an external live transcription
    /// controller. Set before calling `start(...)` — the next capture session
    /// hands a copy of every mic/app buffer to these sinks alongside the
    /// existing file write. Default nil = batch-only behaviour preserved.
    var micLiveSink: LiveAudioSink?
    var appLiveSink: LiveAudioSink?

    /// Start recording app audio and optionally mic.
    func start(
        appPID: pid_t,
        noMic: Bool = false,
        micDeviceUID: String? = nil,
        debugLogging: Bool = false,
    ) throws {
        guard !isRecording else { return }
        guard #available(macOS 14.2, *) else {
            throw RecorderError.unsupportedOS
        }

        let recDir = Self.recordingsDir
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let ts = Self.timestamp()
        startTimestamp = ts

        // ── AudioTapLib capture session ──
        let appTempURL = recDir.appendingPathComponent("\(ts)_app_raw.tmp")
        let micURL: URL? = noMic ? nil : recDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.mic)")

        // Electron/WebView2 apps (Teams 2.x, Slack, Discord) render call
        // audio in helper/renderer children rather than the shell process
        // the OS sees as the window owner. Tap the whole bundle tree so we
        // catch whichever child holds the audio handle; fall back to the
        // root PID alone if the bundle URL is unavailable.
        let effectivePids = Self.resolveTapPIDs(rootPID: appPID)

        let session = AudioCaptureSession(
            pids: effectivePids,
            appOutputURL: appTempURL,
            sampleRate: recordRate,
            channels: appChannels,
            micOutputURL: micURL,
            micDeviceUID: (micDeviceUID?.isEmpty ?? true) ? nil : micDeviceUID,
            debugLogging: debugLogging,
            appLiveSink: appLiveSink,
            micLiveSink: micLiveSink,
        )
        try session.start()
        captureSession = session

        isRecording = true
        recordingStartTime = ProcessInfo.processInfo.systemUptime

        logger.info("Recording started: PID \(appPID), \(self.recordRate) Hz, \(self.appChannels)ch")
    }

    /// Stop recording and produce a mixed WAV. The capture session is the only
    /// hardware-bound part; everything after `session.stop()` is delegated to
    /// the testable `buildRecording`.
    func stop() throws -> RecordingResult {
        guard isRecording else {
            throw RecorderError.notRecording
        }
        guard #available(macOS 14.2, *) else {
            throw RecorderError.unsupportedOS
        }

        let recordingStart = recordingStartTime
        isRecording = false

        // Stop capture session and get result
        guard let session = captureSession else {
            throw RecorderError.noAudioData
        }
        let captureResult = session.stop()
        captureSession = nil

        let ts = startTimestamp ?? Self.timestamp()
        startTimestamp = nil

        return try Self.buildRecording(
            from: captureResult,
            recordingsDir: Self.recordingsDir,
            timestamp: ts,
            recordingStart: recordingStart,
            format: CaptureFormat(requestedChannels: appChannels, requestedRate: recordRate, targetRate: targetRate),
        )
    }

    /// Convert a finished `AudioCaptureResult` (raw app `.tmp` + optional mic
    /// WAV) into a mixed 16 kHz `RecordingResult`: cross-check the rate, downmix
    /// + resample the app track, load the mic track, then mix or fall back to a
    /// single track. Pure file-processing — no capture session, no `@available`
    /// gate — so it is unit-testable with fixture files.
    static func buildRecording( // swiftlint:disable:this function_body_length
        from captureResult: AudioCaptureResult,
        recordingsDir recDir: URL,
        timestamp ts: String,
        recordingStart: TimeInterval,
        format: CaptureFormat,
    ) throws -> RecordingResult {
        let micDelay = captureResult.micDelay
        let actualChannels = captureResult.actualChannels

        // Query raw file size before it gets deleted — needed for rate cross-check
        let tempURL = captureResult.appAudioFileURL
        let appRawBytes = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0

        // Cross-check rate using mic duration (mic file is opened once here, reused below)
        let micDuration: Double? = if let micURL = captureResult.micAudioFileURL,
                                      let micFile = try? AVAudioFile(forReading: micURL),
                                      micFile.processingFormat.sampleRate > 0 {
            Double(micFile.length) / micFile.processingFormat.sampleRate
        } else {
            nil
        }

        let actualRate = crossCheckAppRate(
            deviceRate: captureResult.actualSampleRate,
            appRawBytes: appRawBytes,
            appChannels: actualChannels,
            micDurationSeconds: micDuration,
            micDelay: micDelay,
        )

        if micDelay != 0 {
            logger.info("Mic delay: \(micDelay)s")
        }
        logger.info("App audio: \(actualChannels)ch, \(actualRate) Hz (requested: \(format.requestedChannels)ch, \(format.requestedRate) Hz)")
        if actualChannels != format.requestedChannels {
            logger.warning("App audio channel count differs: actual=\(actualChannels), expected=\(format.requestedChannels) — mono USB device?")
        }
        if actualRate != format.requestedRate {
            logger.warning("App audio rate differs: actual=\(actualRate), expected=\(format.requestedRate) — USB device may have negotiated different rate")
        }

        // ── Convert app audio from temp file to Float32 mono ──
        var appPath: URL?
        var appSamples: [Float] = []
        var appSamples16k: [Float] = []

        if appRawBytes > 0 {
            let raw = try Data(contentsOf: tempURL)
            try? FileManager.default.removeItem(at: tempURL)

            let floatCount = raw.count / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: floatCount)
            raw.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    floats.withUnsafeMutableBufferPointer { dest in
                        dest.baseAddress!.initialize( // swiftlint:disable:this force_unwrapping
                            from: base.assumingMemoryBound(to: Float.self),
                            count: floatCount,
                        )
                    }
                }
            }

            appSamples = downmixToMono(floats, channels: actualChannels)

            // Resample to 16kHz and save app track
            appSamples16k = AudioMixer.resample(appSamples, from: actualRate, to: format.targetRate)
            let appFile = recDir.appendingPathComponent("\(ts)\(RecordingFileSuffix.app)")
            try AudioMixer.saveWAV(samples: appSamples16k, sampleRate: format.targetRate, url: appFile)
            appPath = appFile
            logger.info("App audio saved: \(appFile.lastPathComponent) (\(actualRate)→\(format.targetRate) Hz)")
        } else if FileManager.default.fileExists(atPath: tempURL.path) {
            // Clean up empty temp file left by failed app audio capture
            try? FileManager.default.removeItem(at: tempURL)
            logger.warning("App audio capture produced 0 bytes — temp file cleaned up")
        }

        if appPath == nil {
            logger.warning("No app audio captured — capture may have failed to create the tap")
        }

        // ── Load mic audio ──
        var micPath: URL?
        var micSamples: [Float] = []
        let expectedMicPath = captureResult.micAudioFileURL

        if let expectedMicPath,
           FileManager.default.fileExists(atPath: expectedMicPath.path),
           (try? FileManager.default.attributesOfItem(atPath: expectedMicPath.path)[.size] as? Int) ?? 0 > 44 {
            let micAudioFile = try AVAudioFile(forReading: expectedMicPath)
            let micFileRate = Int(micAudioFile.processingFormat.sampleRate)
            micSamples = try AudioMixer.loadAudioFileAsFloat32(url: expectedMicPath)
            micPath = expectedMicPath
            logger.info("Mic audio loaded: \(expectedMicPath.lastPathComponent) (\(micFileRate) Hz)")
        }

        // ── Mix via AudioMixer ──
        // Both app and mic are already at 16kHz at this point.
        let mixRate = format.targetRate
        let mixPath = recDir.appendingPathComponent("\(ts)\(Self.mixFilenameSuffix)")

        if let app = appPath, let mic = micPath {
            // Delegate mute masking, echo suppression, delay alignment, and mixing
            try AudioMixer.mix(
                appAudioPath: app,
                micAudioPath: mic,
                outputPath: mixPath,
                micDelay: micDelay,
                sampleRate: mixRate,
            )
        } else if !appSamples16k.isEmpty {
            try AudioMixer.saveWAV(samples: appSamples16k, sampleRate: mixRate, url: mixPath)
        } else if !micSamples.isEmpty {
            try AudioMixer.saveWAV(samples: micSamples, sampleRate: mixRate, url: mixPath)
        } else {
            throw RecorderError.noAudioData
        }

        logger.info("Mix saved: \(mixPath.lastPathComponent)")

        return RecordingResult(
            mixPath: mixPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: micDelay,
            recordingStart: recordingStart,
        )
    }

    /// Resolve the PID set to tap for a meeting-matched root PID.
    ///
    /// Returns `[rootPID]` alone when the running-application bundle URL is
    /// unavailable (command-line tool, detached process) or enumeration
    /// finds no PIDs under it. Otherwise returns every PID under the bundle,
    /// prepending the root if enumeration somehow missed it — order matters
    /// for the aggregate device's cosmetic name tag (root first).
    static func resolveTapPIDs(rootPID: pid_t) -> [pid_t] {
        guard let bundleURL = NSRunningApplication(processIdentifier: rootPID)?.bundleURL else {
            return [rootPID]
        }
        let enumerated = ProcessTreeEnumerator.pidsRooted(in: bundleURL)
        guard !enumerated.isEmpty else { return [rootPID] }
        return enumerated.contains(rootPID) ? enumerated : [rootPID] + enumerated
    }

    /// Downmix interleaved multi-channel audio to mono. Passthrough if already mono.
    static func downmixToMono(_ samples: [Float], channels: Int) -> [Float] {
        guard channels >= 2, samples.count >= channels else { return samples }
        let n = samples.count - (samples.count % channels)
        var mono = [Float](repeating: 0, count: n / channels)
        let scale = 1.0 / Float(channels)
        for i in 0 ..< mono.count {
            var sum: Float = 0
            for ch in 0 ..< channels {
                sum += samples[i * channels + ch]
            }
            mono[i] = sum * scale
        }
        return mono
    }

    /// Cross-check the device-reported sample rate against raw file size and mic duration.
    /// Returns the corrected rate (snapped to standard), or the device rate if cross-check
    /// is unavailable or agrees.
    static func crossCheckAppRate(
        deviceRate: Int,
        appRawBytes: Int,
        appChannels: Int,
        micDurationSeconds: Double?,
        micDelay: TimeInterval,
    ) -> Int {
        guard let micDuration = micDurationSeconds, micDuration > 3.0 else {
            return deviceRate
        }
        let appDuration = micDuration + micDelay
        guard appDuration > 3.0 else { return deviceRate }

        guard let inferred = SampleRateQuery.inferRateFromDuration(
            rawBytes: appRawBytes,
            bytesPerSample: MemoryLayout<Float>.size,
            channels: max(appChannels, 1),
            durationSeconds: appDuration,
        ) else { return deviceRate }

        let snapped = SampleRateQuery.snapToStandardRate(inferred)

        // Only override if significantly different (> 5% deviation)
        let deviation = abs(Double(snapped - deviceRate)) / Double(max(deviceRate, 1))
        if deviation > 0.05 {
            logger.warning("Rate cross-check: device=\(deviceRate), inferred=\(inferred), snapped=\(snapped) — overriding")
            return snapped
        }
        return deviceRate
    }

    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}

enum RecorderError: LocalizedError {
    case notRecording
    case noAudioData
    case unsupportedOS
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .notRecording: "Not currently recording"
        case .noAudioData: "No audio data recorded"
        case .unsupportedOS: "macOS 14.2+ required for audio capture"
        case let .permissionDenied(reason): "Permission problem: \(reason)"
        }
    }
}
