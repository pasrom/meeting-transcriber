import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolGenerator")

/// Abstraction for protocol generation, enabling mock injection in tests.
protocol ProtocolGenerating {
    func generate(transcript: String, title: String, diarized: Bool) async throws -> String
}

/// Shared protocol utilities: prompts, file operations, and error types.
enum ProtocolGenerator {
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

    /// Load the protocol prompt, preferring a custom file over the built-in default.
    ///
    /// Reads `AppPaths.customPromptFile` if it exists and is non-empty,
    /// otherwise falls back to the hardcoded `protocolPrompt`.
    static func loadPrompt() -> String {
        let url = AppPaths.customPromptFile
        if let custom = try? String(contentsOf: url, encoding: .utf8),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("Using custom protocol prompt from \(url.path)")
            return custom
        }
        return protocolPrompt
    }

    // MARK: - File Operations

    /// Save a transcript to a text file.
    ///
    /// - Returns: URL of the saved file
    static func saveTranscript(_ text: String, title: String, dir: URL) throws -> URL {
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
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
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename(title: title, ext: "md"))
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Protocol saved: \(url.lastPathComponent)")
        return url
    }

    private static let filenameFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmm"
        return fmt
    }()

    /// Generate a filename: `{yyyyMMdd_HHmm}_{slug}.{ext}`
    static func filename(title: String, ext: String) -> String {
        let date = filenameFormatter.string(from: Date())
        let slug = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { !"/:\\\u{0}".contains($0) }
        return "\(date)_\(slug).\(ext)"
    }
}

enum ProtocolError: LocalizedError {
    #if !APPSTORE
        case cliNotFound(String)
        case cliFailed(Int, String)
        case timeout
    #endif
    case emptyProtocol
    case httpError(Int, String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        #if !APPSTORE
            case let .cliNotFound(bin): "'\(bin)' CLI not found. Install: npm install -g @anthropic-ai/claude-code"
            case let .cliFailed(code, stderr): "Claude CLI exited with code \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"
            case .timeout: "Claude CLI took too long (>10 min)"
        #endif

        case .emptyProtocol: "Protocol is empty. Tip: Test manually: echo Hello | claude --print"
        case let .httpError(code, body): "HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
        case let .connectionFailed(reason): "Connection failed: \(reason)"
        }
    }
}
