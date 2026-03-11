import AVFoundation
import Darwin
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
    let recordingStart: TimeInterval  // ProcessInfo.systemUptime
}

/// Abstraction for recording, enabling mock injection in tests.
@MainActor
protocol RecordingProvider {
    func start(appPID: pid_t, noMic: Bool, micDeviceUID: String?) throws
    func stop() throws -> RecordingResult
}

/// Orchestrates audiotap (app audio) + mic recording, then mixes.
@MainActor
@Observable
class DualSourceRecorder: RecordingProvider {
    private var audiotapProcess: Process?
    private var muteDetector: MuteDetector?
    private var appAudioFileHandle: FileHandle?
    private var appAudioTempURL: URL?
    private var readerTask: Task<Void, Never>?
    private(set) var isRecording = false
    private(set) var recordingStartTime: TimeInterval = 0
    private var startTimestamp: String?

    private let recordRate = 48000
    private let appChannels = 2

    /// Find the audiotap binary.
    static func findAudiotap() -> URL? {
        // 1. Bundle resources
        if let res = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: res).appendingPathComponent("audiotap")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }

        // 2. AUDIOTAP_BINARY env var
        if let env = ProcessInfo.processInfo.environment["AUDIOTAP_BINARY"] {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        // 3. Project-local build
        if let root = Permissions.findProjectRoot(from: nil) {
            let local = URL(fileURLWithPath: root)
                .appendingPathComponent("tools/audiotap/.build/release/audiotap")
            if FileManager.default.isExecutableFile(atPath: local.path) {
                return local
            }
        }

        return nil
    }

    /// Recordings directory.
    static var recordingsDir: URL {
        AppPaths.recordingsDir
    }

    /// Path to the PID file for orphan detection.
    static var pidFilePath: URL {
        AppPaths.ipcDir.appendingPathComponent("audiotap.pid")
    }

    /// Kill an orphaned audiotap process from a previous crash.
    /// Reads the PID file, verifies via `proc_pidpath` that it's actually audiotap,
    /// sends SIGTERM, waits briefly, then SIGKILL if still alive.
    static func killOrphanedAudiotap() {
        let pidFile = pidFilePath
        guard FileManager.default.fileExists(atPath: pidFile.path) else { return }
        defer { try? FileManager.default.removeItem(at: pidFile) }

        guard let content = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(content), pid > 0 else {
            return
        }

        // Verify this PID is actually an audiotap process
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        guard len > 0 else { return } // process doesn't exist

        let procPath = String(cString: pathBuf)
        guard procPath.hasSuffix("/audiotap") || procPath.hasSuffix("/audiotap.debug") else {
            logger.info("PID \(pid) is not audiotap (\(procPath)), skipping kill")
            return
        }

        logger.info("Killing orphaned audiotap PID \(pid)")
        kill(pid, SIGTERM)

        // Wait up to 500ms for graceful exit
        var waited = 0
        while waited < 5 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
            if kill(pid, 0) != 0 { return } // process gone
        }

        // Force kill if still alive
        kill(pid, SIGKILL)
        logger.info("Force-killed orphaned audiotap PID \(pid)")
    }

    /// Start recording app audio and optionally mic.
    func start(
        appPID: pid_t,
        noMic: Bool = false,
        micDeviceUID: String? = nil
    ) throws {
        guard !isRecording else { return }

        let recDir = Self.recordingsDir
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)

        let ts = Self.timestamp()
        startTimestamp = ts

        // ── audiotap subprocess ──
        guard let audiotapBin = Self.findAudiotap() else {
            throw RecorderError.audiotapNotFound
        }

        var args = [String(appPID), String(recordRate), String(appChannels)]

        var micWavPath: URL?
        if !noMic {
            let micPath = recDir.appendingPathComponent("\(ts)_mic.wav")
            args += ["--mic", micPath.path]
            micWavPath = micPath
            if let uid = micDeviceUID, !uid.isEmpty {
                args += ["--mic-device", uid]
            }
        }

        let proc = Process()
        proc.executableURL = audiotapBin
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Stream app audio to temp file instead of accumulating in RAM
        let tempURL = recDir.appendingPathComponent("\(ts)_app_raw.tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        appAudioTempURL = tempURL
        appAudioFileHandle = try FileHandle(forWritingTo: tempURL)

        try proc.run()
        audiotapProcess = proc
        isRecording = true
        recordingStartTime = ProcessInfo.processInfo.systemUptime

        // Write PID file for orphan detection on crash recovery
        let pidFile = Self.pidFilePath
        try? FileManager.default.createDirectory(
            at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(proc.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)

        logger.info("Recording started: PID \(appPID), \(self.recordRate) Hz, \(self.appChannels)ch")

        // Stream stdout to temp file in background
        let writeHandle = appAudioFileHandle!
        readerTask = Task.detached {
            let handle = stdoutPipe.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                writeHandle.write(data)
            }
        }

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
    func stop() throws -> RecordingResult {
        guard isRecording else {
            throw RecorderError.notRecording
        }

        let recordingStart = recordingStartTime
        isRecording = false

        // Stop mute detector
        let muteTimeline = muteDetector?.timeline ?? []
        muteDetector?.stop()
        muteDetector = nil

        // Terminate audiotap
        if let proc = audiotapProcess, proc.isRunning {
            proc.terminate()
            // Wait up to 3 seconds
            let deadline = Date().addingTimeInterval(3)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                proc.waitUntilExit()
            }
        }

        readerTask?.cancel()
        readerTask = nil

        // Parse stderr
        var micDelay: TimeInterval = 0
        var actualRate = recordRate
        if let proc = audiotapProcess,
           let stderrPipe = proc.standardError as? Pipe {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if let stderr = String(data: stderrData, encoding: .utf8) {
                for line in stderr.split(separator: "\n") {
                    if line.hasPrefix("MIC_DELAY="), let val = Double(line.dropFirst(10)) {
                        micDelay = val
                        logger.info("Mic delay: \(micDelay)s")
                    } else if line.hasPrefix("ACTUAL_RATE="), let val = Int(line.dropFirst(12)) {
                        actualRate = val
                        logger.info("Actual app rate: \(actualRate) Hz")
                    }
                }
            }
        }
        audiotapProcess = nil
        try? FileManager.default.removeItem(at: Self.pidFilePath)

        let recDir = Self.recordingsDir
        let ts = startTimestamp ?? Self.timestamp()
        startTimestamp = nil

        // ── Convert app audio from temp file to Float32 mono ──
        var appPath: URL?
        var appSamples: [Float] = []

        // Close file handle and read back
        appAudioFileHandle?.closeFile()
        appAudioFileHandle = nil
        let tempURL = appAudioTempURL
        appAudioTempURL = nil

        if let tempURL, FileManager.default.fileExists(atPath: tempURL.path),
           (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0 > 0 {
            let raw = try Data(contentsOf: tempURL)
            try? FileManager.default.removeItem(at: tempURL)

            let floatCount = raw.count / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: floatCount)
            raw.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    floats.withUnsafeMutableBufferPointer { dest in
                        dest.baseAddress!.initialize(
                            from: base.assumingMemoryBound(to: Float.self),
                            count: floatCount
                        )
                    }
                }
            }

            // Stereo → mono
            if appChannels == 2 && floats.count >= 2 {
                let n = floats.count - (floats.count % 2)
                var mono = [Float](repeating: 0, count: n / 2)
                for i in 0..<mono.count {
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
        }

        // ── Load mic audio (written by audiotap) ──
        var micPath: URL?
        var micSamples: [Float] = []
        let expectedMicPath = recDir.appendingPathComponent("\(ts)_mic.wav")

        if FileManager.default.fileExists(atPath: expectedMicPath.path),
           (try? FileManager.default.attributesOfItem(atPath: expectedMicPath.path)[.size] as? Int) ?? 0 > 44 {
            let micAudioFile = try AVAudioFile(forReading: expectedMicPath)
            let micFileRate = Int(micAudioFile.processingFormat.sampleRate)
            micSamples = try AudioMixer.loadWAVAsFloat32(url: expectedMicPath)
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
                sampleRate: recordRate
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
            recordingStart: recordingStart
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
    case audiotapNotFound
    case notRecording
    case noAudioData

    var errorDescription: String? {
        switch self {
        case .audiotapNotFound: "audiotap binary not found. Build: cd tools/audiotap && swift build -c release"
        case .notRecording: "Not currently recording"
        case .noAudioData: "No audio data recorded"
        }
    }
}
