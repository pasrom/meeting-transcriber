import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolGenerator")

/// Abstraction for protocol generation, enabling mock injection in tests.
protocol ProtocolGenerating {
    func generate(transcript: String, title: String, diarized: Bool) async throws -> String
}

/// Claude CLI implementation that delegates to `ProtocolGenerator.generate(...)`.
struct ClaudeCLIProtocolGenerator: ProtocolGenerating {
    let claudeBin: String

    func generate(transcript: String, title: String, diarized: Bool) async throws -> String {
        try await ProtocolGenerator.generate(transcript: transcript, title: title, diarized: diarized, claudeBin: claudeBin)
    }
}

/// Generates meeting protocols by calling the Claude CLI as a subprocess.
struct ProtocolGenerator {

    static let timeoutSeconds: TimeInterval = 600

    static let protocolPrompt = """
        You are a professional meeting minute taker.
        Create a structured meeting protocol in German from the following transcript.

        Return ONLY the finished Markdown document - no explanations, no introduction,
        no comments before or after.

        Use exactly this structure:

        # Meeting Protocol - [Meeting Title]
        **Date:** [Date from context or today]

        ---

        ## Summary
        [3-5 sentence summary of the meeting]

        ## Participants
        - [Name 1]
        - [Name 2]

        ## Topics Discussed

        ### [Topic 1]
        [What was discussed]

        ### [Topic 2]
        [What was discussed]

        ## Decisions
        - [Decision 1]
        - [Decision 2]

        ## Tasks
        | Task | Responsible | Deadline | Priority |
        |------|-------------|----------|----------|
        | [Description] | [Name] | [Date or open] | 🔴 high / 🟡 medium / 🟢 low |

        ## Open Questions
        - [Question 1]
        - [Question 2]

        Do NOT include the full transcript in the output – it will be appended automatically.

        ---
        Transcript:
        """

    static let diarizationNote = """
        \nNote: The transcript contains speaker labels in brackets. \
        Possible label formats:
        - [SPEAKER_00], [SPEAKER_01] — auto-detected speakers (use Speaker 1, Speaker 2)
        - [Me], [Roman] etc. — the local microphone user
        - [Remote] — remote participant(s) without diarization
        - [Name] — a recognized or named speaker
        Use these labels to identify participants. \
        In the Participants section, list them by name where possible. \
        In the Topics Discussed section, attribute key statements to speakers.

        """

    /// Generate a meeting protocol from a transcript using the Claude CLI.
    ///
    /// - Parameters:
    ///   - transcript: The meeting transcript text
    ///   - title: Meeting title for the protocol header
    ///   - diarized: Whether the transcript contains speaker labels
    ///   - claudeBin: Path to the claude CLI binary
    /// - Returns: The generated protocol as Markdown
    static func generate(
        transcript: String,
        title: String = "Meeting",
        diarized: Bool = false,
        claudeBin: String = "claude"
    ) async throws -> String {
        var prompt = protocolPrompt
        if diarized {
            prompt += diarizationNote
        }
        prompt += transcript

        let process = Process()
        let resolvedBin = Self.resolveClaudePath(claudeBin)
        process.executableURL = URL(fileURLWithPath: resolvedBin)
        var args = ["-p", "-", "--output-format", "stream-json", "--verbose", "--model", "sonnet"]
        // If using /usr/bin/env fallback, prepend the binary name
        if resolvedBin == "/usr/bin/env" {
            args.insert(claudeBin, at: 0)
        }
        process.arguments = args

        // Remove CLAUDECODE env var to allow nested Claude CLI invocation
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        // App bundles have a minimal PATH — ensure common bin dirs are included
        // so wrapper scripts (e.g. claude-work-wrapper calling `exec claude`) work
        let extraPaths = Self.searchPaths.joined(separator: ":")
        env["PATH"] = "\(extraPaths):\(env["PATH"] ?? "/usr/bin:/bin")"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // C5 fix: Set terminationHandler BEFORE process.run() to avoid race
        // where the process exits before the handler is installed.
        // AsyncStream buffers the yield, so even if the process exits before
        // we iterate, the value is not lost.
        let exitStream = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw ProtocolError.cliNotFound(claudeBin)
        }

        // C5 fix: Guard against process having already exited before we awaited.
        // If the process already exited, terminationHandler may have already fired,
        // but AsyncStream buffers the yield so we won't miss it.
        // No additional check needed — AsyncStream handles the race.

        logger.info("Generating protocol with Claude CLI ...")

        // C6 fix: Write stdin in a detached task to avoid deadlock on large transcripts.
        // The pipe buffer is finite (~64KB); if the prompt exceeds it, a synchronous
        // write blocks until the reader drains — but we haven't started reading yet.
        let promptData = Data(prompt.utf8)
        let stdinWriteTask = Task.detached {
            stdinPipe.fileHandleForWriting.write(promptData)
            stdinPipe.fileHandleForWriting.closeFile()
        }

        // Read stream-json output concurrently with stdin write
        let text = try await readStreamJSON(from: stdoutPipe, process: process)

        // Ensure stdin write completes (should be done by now)
        _ = await stdinWriteTask.value

        // Read stderr in background to prevent pipe buffer issues
        async let stderrRead = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

        // Await process exit via the stream installed before launch
        for await _ in exitStream { break }

        if process.terminationStatus != 0 {
            let stderrData = await stderrRead
            let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ProtocolError.cliFailed(Int(process.terminationStatus), stderrText)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProtocolError.emptyProtocol
        }

        return trimmed
    }

    /// Parse Claude CLI stream-json output and accumulate text.
    private static func readStreamJSON(from pipe: Pipe, process: Process) async throws -> String {
        let handle = pipe.fileHandleForReading
        var parts: [String] = []
        let startTime = ProcessInfo.processInfo.systemUptime

        // Read line-by-line from stdout
        var buffer = Data()
        while true {
            if ProcessInfo.processInfo.systemUptime - startTime > timeoutSeconds {
                process.terminate()
                throw ProtocolError.timeout
            }

            // I1 fix: Wrap blocking availableData in Task.detached to avoid
            // blocking Swift's cooperative thread pool. availableData blocks
            // until data is available or EOF, which would starve other tasks.
            let chunk = await Task.detached { handle.availableData }.value
            if chunk.isEmpty { break } // EOF

            buffer.append(chunk)

            // Process complete lines
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                guard let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !line.isEmpty else { continue }

                if let text = parseStreamJSONLine(line) {
                    parts.append(text)
                }
            }
        }

        return parts.joined()
    }

    /// Parse a single stream-json line and extract text content.
    static func parseStreamJSONLine(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // content_block_delta carries streaming text chunks
        if obj["type"] as? String == "content_block_delta",
           let delta = obj["delta"] as? [String: Any],
           delta["type"] as? String == "text_delta",
           let text = delta["text"] as? String {
            return text
        }

        // assistant message carries the final full text
        if obj["type"] as? String == "assistant",
           let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "text",
                   let text = block["text"] as? String {
                    return text
                }
            }
        }

        return nil
    }

    // MARK: - CLI Resolution

    /// Search paths for Claude CLI binaries.
    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.npm-global/bin",
        "/opt/homebrew/bin",
    ]

    /// Scan known install locations for executables starting with "claude".
    /// Always includes "claude" as a fallback even if not found.
    static func availableClaudeBinaries() -> [String] {
        let fm = FileManager.default
        var names = Set<String>()

        for dir in searchPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasPrefix("claude") {
                let full = "\(dir)/\(entry)"
                if fm.isExecutableFile(atPath: full) {
                    names.insert(entry)
                }
            }
        }

        names.insert("claude")
        return names.sorted()
    }

    /// Resolve the claude CLI binary path.
    /// App bundles have a restricted PATH, so check common install locations.
    static func resolveClaudePath(_ bin: String) -> String {
        // If already an absolute path, use it
        if bin.hasPrefix("/") { return bin }

        for path in searchPaths.map({ "\($0)/\(bin)" }) {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: hope it's in PATH
        return "/usr/bin/env"
    }

    // MARK: - File Operations

    /// Save a transcript to a text file.
    ///
    /// - Returns: URL of the saved file
    static func saveTranscript(_ text: String, title: String, dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename(title: title, ext: "txt"))
        try text.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Transcript saved: \(url.lastPathComponent)")
        return url
    }

    /// Save a protocol to a Markdown file.
    ///
    /// - Returns: URL of the saved file
    static func saveProtocol(_ markdown: String, title: String, dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename(title: title, ext: "md"))
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Protocol saved: \(url.lastPathComponent)")
        return url
    }

    /// Generate a filename: `{yyyyMMdd_HHmm}_{slug}.{ext}`
    static func filename(title: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let date = formatter.string(from: Date())
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "_")
        return "\(date)_\(slug).\(ext)"
    }
}

enum ProtocolError: LocalizedError {
    case cliNotFound(String)
    case cliFailed(Int, String)
    case emptyProtocol
    case timeout

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let bin): "'\(bin)' CLI not found. Install: npm install -g @anthropic-ai/claude-code"
        case .cliFailed(let code, let stderr): "Claude CLI exited with code \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .emptyProtocol: "Protocol is empty. Tip: Test manually: echo Hello | claude --print"
        case .timeout: "Claude CLI took too long (>10 min)"
        }
    }
}
