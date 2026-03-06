import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber", category: "DualSourceRecorder")

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
protocol RecordingProvider {
    func start(appPID: pid_t, noMic: Bool, micDeviceUID: String?) throws
    func stop() throws -> RecordingResult
}

/// Orchestrates audiotap (app audio) + mic recording, then mixes.
@Observable
class DualSourceRecorder: RecordingProvider {
    private var audiotapProcess: Process?
    private var micRecorder: MicRecorder?
    private var muteDetector: MuteDetector?
    private var appAudioFrames: [Data] = []
    private var readerTask: Task<Void, Never>?
    private(set) var isRecording = false

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
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingTranscriber/recordings")
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

        appAudioFrames = []

        try proc.run()
        audiotapProcess = proc
        isRecording = true

        logger.info("Recording started: PID \(appPID), \(self.recordRate) Hz, \(self.appChannels)ch")

        // Read stdout in background
        let chunkSize = recordRate * appChannels * 4 * 10 / 1000  // 10ms of float32 stereo
        readerTask = Task.detached { [weak self] in
            let handle = stdoutPipe.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                await MainActor.run {
                    self?.appAudioFrames.append(data)
                }
            }
            _ = chunkSize  // suppress warning
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

        let recordingStart = ProcessInfo.processInfo.systemUptime
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

        let recDir = Self.recordingsDir
        let ts = Self.timestamp()

        // ── Convert app audio frames to Float32 mono ──
        var appPath: URL?
        var appSamples: [Float] = []
        if !appAudioFrames.isEmpty {
            let raw = appAudioFrames.reduce(Data()) { $0 + $1 }
            appAudioFrames = []

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
        // audiotap writes to the path we passed in start(), try to find it
        let micFiles = try? FileManager.default.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil)
        let latestMic = micFiles?
            .filter { $0.lastPathComponent.hasSuffix("_mic.wav") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first

        if let micFile = latestMic,
           FileManager.default.fileExists(atPath: micFile.path),
           (try? FileManager.default.attributesOfItem(atPath: micFile.path)[.size] as? Int) ?? 0 > 44 {
            micSamples = try AudioMixer.loadWAVAsFloat32(url: micFile)
            micPath = micFile
            logger.info("Mic audio loaded: \(micFile.lastPathComponent)")
        }

        // ── Apply mute mask ──
        if !muteTimeline.isEmpty && !micSamples.isEmpty {
            AudioMixer.applyMuteMask(
                samples: &micSamples,
                timeline: muteTimeline,
                sampleRate: recordRate,
                micDelay: micDelay,
                recordingStart: recordingStart
            )
        }

        // ── Echo suppression ──
        if !appSamples.isEmpty && !micSamples.isEmpty {
            AudioMixer.suppressEcho(
                appSamples: appSamples,
                micSamples: &micSamples,
                sampleRate: recordRate,
                micDelay: micDelay
            )
        }

        // ── Delay alignment ──
        if micDelay > 0 {
            let delaySamples = Int(micDelay * Double(recordRate))
            if delaySamples > 0 && delaySamples < micSamples.count {
                micSamples = [Float](repeating: 0, count: delaySamples) + micSamples
            }
        } else if micDelay < 0 {
            let delaySamples = Int(-micDelay * Double(recordRate))
            if delaySamples > 0 && delaySamples < appSamples.count {
                appSamples = [Float](repeating: 0, count: delaySamples) + appSamples
            }
        }

        // ── Mix ──
        let mixed = AudioMixer.mixTracks(appSamples, micSamples)

        guard !mixed.isEmpty else {
            throw RecorderError.noAudioData
        }

        let mixPath = recDir.appendingPathComponent("\(ts)_mix.wav")
        try AudioMixer.saveWAV(samples: mixed, sampleRate: recordRate, url: mixPath)
        logger.info("Mix saved: \(mixPath.lastPathComponent) (\(Double(mixed.count) / Double(self.recordRate))s)")

        return RecordingResult(
            mixPath: mixPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: micDelay,
            muteTimeline: muteTimeline,
            recordingStart: recordingStart
        )
    }

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt.string(from: Date())
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
