import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber", category: "DiarizationProcess")

/// Result from the standalone diarize.py script.
struct DiarizationResult {
    struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
    }

    let segments: [Segment]
    let speakingTimes: [String: TimeInterval]
    let autoNames: [String: String]
}

/// Abstraction for diarization, enabling mock injection in tests.
protocol DiarizationProvider {
    var isAvailable: Bool { get }
    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult
}

/// Runs the standalone Python diarization script as a subprocess.
class DiarizationProcess: DiarizationProvider {
    private let pythonPath: URL
    private let scriptPath: URL
    private let ipcDir: URL

    /// Whether the diarization venv exists in the bundle.
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: pythonPath.path)
            && FileManager.default.fileExists(atPath: scriptPath.path)
    }

    init(
        pythonPath: URL? = nil,
        scriptPath: URL? = nil,
        ipcDir: URL? = nil
    ) {
        let fm = FileManager.default

        if let pythonPath {
            self.pythonPath = pythonPath
        } else if let res = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: res)
                .appendingPathComponent("python-diarize/bin/python3")
            if fm.fileExists(atPath: bundled.path) {
                self.pythonPath = bundled
            } else if let root = Permissions.findProjectRoot(from: nil) {
                // Dev mode: use project venv
                self.pythonPath = URL(fileURLWithPath: root)
                    .appendingPathComponent(".venv/bin/python")
            } else {
                self.pythonPath = URL(fileURLWithPath: "/usr/bin/python3")
            }
        } else {
            self.pythonPath = URL(fileURLWithPath: "/usr/bin/python3")
        }

        if let scriptPath {
            self.scriptPath = scriptPath
        } else if let res = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: res)
                .appendingPathComponent("python-diarize/diarize.py")
            if fm.fileExists(atPath: bundled.path) {
                self.scriptPath = bundled
            } else if let root = Permissions.findProjectRoot(from: nil) {
                // Dev mode: use standalone diarize script
                self.scriptPath = URL(fileURLWithPath: root)
                    .appendingPathComponent("tools/diarize/diarize.py")
            } else {
                self.scriptPath = URL(fileURLWithPath: "diarize.py")
            }
        } else {
            self.scriptPath = URL(fileURLWithPath: "diarize.py")
        }

        self.ipcDir = ipcDir ?? fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
    }

    /// Run diarization on an audio file.
    func run(
        audioPath: URL,
        numSpeakers: Int? = nil,
        expectedNames: [String] = [],
        speakersDB: URL? = nil,
        meetingTitle: String = "Meeting"
    ) async throws -> DiarizationResult {
        guard isAvailable else {
            throw DiarizationError.notAvailable
        }

        var arguments = [scriptPath.path, audioPath.path]

        if let n = numSpeakers, n > 0 {
            arguments += ["--speakers", String(n)]
        }
        if let db = speakersDB {
            arguments += ["--speakers-db", db.path]
        }
        if !expectedNames.isEmpty {
            arguments += ["--expected-names", expectedNames.joined(separator: ",")]
        }
        arguments += ["--ipc-dir", ipcDir.path]
        arguments += ["--meeting-title", meetingTitle]

        let process = Process()
        process.executableURL = pythonPath
        process.arguments = arguments

        // Set HF_TOKEN from Keychain
        var env = ProcessInfo.processInfo.environment
        if let hfToken = KeychainHelper.read(key: "HF_TOKEN") {
            env["HF_TOKEN"] = hfToken
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        logger.info("Starting diarization: \(audioPath.lastPathComponent)")

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw DiarizationError.processFailed(Int(process.terminationStatus), stderr)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return try parseOutput(stdoutData)
    }

    /// Parse the JSON output from diarize.py.
    static func parseOutput(_ data: Data) throws -> DiarizationResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiarizationError.invalidOutput
        }

        // Parse segments
        let rawSegments = json["segments"] as? [[String: Any]] ?? []
        let segments = rawSegments.compactMap { seg -> DiarizationResult.Segment? in
            guard let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double,
                  let speaker = seg["speaker"] as? String else { return nil }
            return DiarizationResult.Segment(start: start, end: end, speaker: speaker)
        }

        // Parse speaking times
        let rawTimes = json["speaking_times"] as? [String: Double] ?? [:]
        let speakingTimes = rawTimes.mapValues { TimeInterval($0) }

        // Parse auto names
        let autoNames = json["auto_names"] as? [String: String] ?? [:]

        return DiarizationResult(
            segments: segments,
            speakingTimes: speakingTimes,
            autoNames: autoNames
        )
    }

    // Convenience alias for testing
    func parseOutput(_ data: Data) throws -> DiarizationResult {
        try Self.parseOutput(data)
    }

    /// Bridge method satisfying `DiarizationProvider` protocol (fewer parameters).
    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> DiarizationResult {
        try await run(audioPath: audioPath, numSpeakers: numSpeakers, expectedNames: [], speakersDB: nil, meetingTitle: meetingTitle)
    }

    /// Assign speaker labels to transcript segments by maximum temporal overlap.
    static func assignSpeakers(
        transcript: [TimestampedSegment],
        diarization: DiarizationResult
    ) -> [TimestampedSegment] {
        transcript.map { seg in
            var best = seg
            var bestOverlap: TimeInterval = 0

            for dSeg in diarization.segments {
                let overlapStart = max(seg.start, dSeg.start)
                let overlapEnd = min(seg.end, dSeg.end)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    best.speaker = dSeg.speaker
                }
            }

            if best.speaker.isEmpty {
                best.speaker = "UNKNOWN"
            }
            return best
        }
    }
}

enum DiarizationError: LocalizedError {
    case notAvailable
    case processFailed(Int, String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Diarization not available (python-diarize not found in bundle)"
        case .processFailed(let code, let stderr):
            "Diarization failed (exit \(code))\(stderr.isEmpty ? "" : ": \(stderr.prefix(200))")"
        case .invalidOutput: "Failed to parse diarization output"
        }
    }
}
