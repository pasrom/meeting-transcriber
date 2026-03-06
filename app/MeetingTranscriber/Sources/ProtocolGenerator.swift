import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber", category: "ProtocolGenerator")

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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            claudeBin, "-p", "-",
            "--output-format", "stream-json",
            "--verbose",
            "--model", "sonnet",
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProtocolError.cliNotFound(claudeBin)
        }

        logger.info("Generating protocol with Claude CLI ...")

        // Write prompt to stdin in background
        let promptData = Data(prompt.utf8)
        stdinPipe.fileHandleForWriting.write(promptData)
        stdinPipe.fileHandleForWriting.closeFile()

        // Read stream-json output
        let text = try await readStreamJSON(from: stdoutPipe, process: process)

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
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

            let chunk = handle.availableData
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
