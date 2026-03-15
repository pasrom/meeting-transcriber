import AudioTapLib
import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "DualSourceRecorder")

/// Result of a recording session.
struct RecordingResult {
    let mixPath: URL
    let appPath: URL?
    let micPath: URL?
    let micDelay: TimeInterval
    let muteTimeline: [MuteTransition]
    let recordingStart: TimeInterval // ProcessInfo.systemUptime
}

/// Abstraction for recording, enabling mock injection in tests.
@MainActor
protocol RecordingProvider {
    func start(appPID: pid_t, noMic: Bool, micDeviceUID: String?) throws
    func stop() throws -> RecordingResult
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
    private var muteDetector: MuteDetector?
    private(set) var isRecording = false
    private(set) var recordingStartTime: TimeInterval = 0
    private var startTimestamp: String?

    private let recordRate = 48000
    private let appChannels = 2

    /// Recordings directory.
    static var recordingsDir: URL {
        AppPaths.recordingsDir
    }

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

    /// Start recording app audio and optionally mic.
    func start(
        appPID: pid_t,
        noMic: Bool = false,
        micDeviceUID: String? = nil,
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
        let micURL: URL? = noMic ? nil : recDir.appendingPathComponent("\(ts)_mic.wav")

        let session = AudioCaptureSession(
            pid: appPID,
            appOutputURL: appTempURL,
            sampleRate: recordRate,
            channels: appChannels,
            micOutputURL: micURL,
            micDeviceUID: (micDeviceUID?.isEmpty ?? true) ? nil : micDeviceUID,
        )
        try session.start()
        captureSession = session

        isRecording = true
        recordingStartTime = ProcessInfo.processInfo.systemUptime

        logger.info("Recording started: PID \(appPID), \(self.recordRate) Hz, \(self.appChannels)ch")

        // ── Mute detection ──
        let detector = MuteDetector(teamsPID: appPID)
        detector.start()
        if detector.isActive {
            muteDetector = detector
            logger.info("Mute detection active")
        } else {
            detector.stop()
        }
    }

    /// Stop recording and produce a mixed WAV.
    func stop() throws -> RecordingResult { // swiftlint:disable:this function_body_length cyclomatic_complexity
        guard isRecording else {
            throw RecorderError.notRecording
        }
        guard #available(macOS 14.2, *) else {
            throw RecorderError.unsupportedOS
        }

        let recordingStart = recordingStartTime
        isRecording = false

        // Stop mute detector
        let muteTimeline = muteDetector?.timeline ?? []
        muteDetector?.stop()
        muteDetector = nil

        // Stop capture session and get result
        guard let session = captureSession else {
            throw RecorderError.noAudioData
        }
        let captureResult = session.stop()
        captureSession = nil

        let micDelay = captureResult.micDelay
        let actualRate = captureResult.actualSampleRate

        if micDelay != 0 {
            logger.info("Mic delay: \(micDelay)s")
        }
        if actualRate != recordRate {
            logger.info("Actual app rate: \(actualRate) Hz")
        }

        let recDir = Self.recordingsDir
        let ts = startTimestamp ?? Self.timestamp()
        startTimestamp = nil

        // ── Convert app audio from temp file to Float32 mono ──
        var appPath: URL?
        var appSamples: [Float] = []

        let tempURL = captureResult.appAudioFileURL

        if FileManager.default.fileExists(atPath: tempURL.path),
           (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0 > 0 {
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

            // Stereo → mono
            if appChannels == 2 && floats.count >= 2 {
                let n = floats.count - (floats.count % 2)
                var mono = [Float](repeating: 0, count: n / 2)
                for i in 0 ..< mono.count {
                    mono[i] = (floats[i * 2] + floats[i * 2 + 1]) / 2
                }
                appSamples = mono
            } else {
                appSamples = floats
            }

            // Save app track
            let appFile = recDir.appendingPathComponent("\(ts)_app.wav")
            try AudioMixer.saveWAV(samples: appSamples, sampleRate: actualRate, url: appFile)
            appPath = appFile
            logger.info("App audio saved: \(appFile.lastPathComponent) (\(actualRate) Hz)")

            // Resample to recordRate if needed
            if actualRate != recordRate {
                appSamples = AudioMixer.resample(appSamples, from: actualRate, to: recordRate)
            }
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

            if micFileRate != recordRate {
                micSamples = AudioMixer.resample(micSamples, from: micFileRate, to: recordRate)
                logger.info("Mic resampled: \(micFileRate) → \(self.recordRate) Hz")
            }
        }

        // ── Mix via AudioMixer ──
        let mixPath = recDir.appendingPathComponent("\(ts)_mix.wav")

        if let app = appPath, let mic = micPath {
            // Delegate mute masking, echo suppression, delay alignment, and mixing
            try AudioMixer.mix(
                appAudioPath: app,
                micAudioPath: mic,
                outputPath: mixPath,
                micDelay: micDelay,
                muteTimeline: muteTimeline,
                recordingStart: recordingStart,
                sampleRate: recordRate,
            )
        } else if !appSamples.isEmpty {
            try AudioMixer.saveWAV(samples: appSamples, sampleRate: recordRate, url: mixPath)
        } else if !micSamples.isEmpty {
            try AudioMixer.saveWAV(samples: micSamples, sampleRate: recordRate, url: mixPath)
        } else {
            throw RecorderError.noAudioData
        }

        logger.info("Mix saved: \(mixPath.lastPathComponent)")

        return RecordingResult(
            mixPath: mixPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: micDelay,
            muteTimeline: muteTimeline,
            recordingStart: recordingStart,
        )
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

    var errorDescription: String? {
        switch self {
        case .notRecording: "Not currently recording"
        case .noAudioData: "No audio data recorded"
        case .unsupportedOS: "macOS 14.2+ required for audio capture"
        }
    }
}
