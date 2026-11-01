import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolGenerator")

/// Abstraction for protocol generation, enabling mock injection in tests.
protocol ProtocolGenerating {
    func generate(transcript: String, title: String, diarized: Bool, meetingStartTime: Date?) async throws -> String
}

/// Shared protocol utilities: prompts, file operations, and error types.
enum ProtocolGenerator {
    struct MeetingPromptMetadata: Equatable {
        let date: String
        let time: String
    }

    static let unknownMeetingMetadata = "Unknown"

    static let protocolPrompt = """
    You are a professional meeting minute taker.
    Create a structured meeting protocol in {LANGUAGE} from the following transcript.

    Return ONLY the finished Markdown document - no explanations, no introduction,
    no comments before or after.

    Use exactly this structure:

    # Meeting Protocol - [Meeting Title]
    **Date:** {MEETING_DATE}
    **Time:** {MEETING_TIME}

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

    Do NOT include the full transcript in the output.

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

    /// Replaces supported protocol-prompt variables with meeting-specific values.
    ///
    /// Dates and times use stable, locale-independent formats so users can
    /// reliably instruct their LLMs to resolve relative time expressions. When
    /// a recording has no captured start time (for example, an import), the
    /// date and time variables resolve to `Unknown` rather than processing time.
    static func applyVariables(
        _ prompt: String,
        language: String,
        metadata: MeetingPromptMetadata?,
    ) -> String {
        prompt
            .replacingOccurrences(of: "{LANGUAGE}", with: language)
            .replacingOccurrences(of: "{MEETING_DATE}", with: metadata?.date ?? unknownMeetingMetadata)
            .replacingOccurrences(of: "{MEETING_TIME}", with: metadata?.time ?? unknownMeetingMetadata)
    }

    /// Load the protocol generation prompt. Reads from `url` (default
    /// `AppPaths.customPromptFile`) when present and non-empty; falls back
    /// to the built-in `protocolPrompt`. The `url` parameter exists so tests
    /// can use unique per-test paths instead of racing on the shared one.
    static func loadPrompt(from url: URL = AppPaths.customPromptFile) -> String {
        if let custom = try? String(contentsOf: url, encoding: .utf8),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("Using custom protocol prompt from \(url.path)")
            return custom
        }
        return protocolPrompt
    }

    /// Build the system prompt from an optional authoritative meeting-time context,
    /// loaded prompt with variables replaced, and optional `diarizationNote`.
    /// Imports and recovery jobs have no reliable meeting start and therefore
    /// receive no authoritative time anchor. Excludes the transcript itself —
    /// callers append or attach it as they see fit.
    ///
    /// `promptURL` is forwarded to `loadPrompt` and exists for the same reason:
    /// without it tests fall through to the shared `AppPaths.customPromptFile`,
    /// so their result depends on whether the developer has customised their own
    /// prompt through the app.
    static func buildSystemPrompt(
        diarized: Bool,
        language: String,
        meetingStartTime: Date?,
        promptURL: URL = AppPaths.customPromptFile,
        timeZone: TimeZone = .autoupdatingCurrent,
    ) -> String {
        let metadata = meetingStartTime.map { meetingMetadata(for: $0, timeZone: timeZone) }
        var prompt = meetingTimeContext(metadata: metadata) + applyVariables(
            loadPrompt(from: promptURL),
            language: language,
            metadata: metadata,
        )
        if diarized { prompt += diarizationNote }
        return prompt
    }

    static func meetingMetadata(
        for meetingStartTime: Date,
        timeZone: TimeZone = .autoupdatingCurrent,
    ) -> MeetingPromptMetadata {
        let dateFormatter = DateFormatter.filenameStamp("yyyy-MM-dd")
        dateFormatter.timeZone = timeZone
        let timeFormatter = DateFormatter.filenameStamp("HH:mm")
        timeFormatter.timeZone = timeZone
        return MeetingPromptMetadata(
            date: dateFormatter.string(from: meetingStartTime),
            time: timeFormatter.string(from: meetingStartTime),
        )
    }

    private static func meetingTimeContext(metadata: MeetingPromptMetadata?) -> String {
        guard let metadata else { return "" }
        return [
            "Meeting metadata:",
            "Date: \(metadata.date)",
            "Time: \(metadata.time)",
            "The date and time above are authoritative. Interpret relative time expressions",
            "in the transcript relative to this meeting date. Do not rely on the model's",
            "assumed current date.",
        ].joined(separator: "\n") + "\n\n"
    }

    // MARK: - File Operations

    /// Save a transcript to a text file.
    ///
    /// `basename` is the job's precomputed, meeting-start-anchored stem (shared
    /// with the protocol and audio artifacts); the `.txt` extension is appended.
    ///
    /// Opens no security scope: `PipelineQueue` holds it on the output root
    /// (see `SecurityScopeAccess`).
    ///
    /// - Returns: URL of the saved file
    static func saveTranscript(_ text: String, basename: String, dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(basename).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        // Transcripts contain verbatim meeting speech — restrict to owner-only.
        try FileManager.default.restrictToOwner(url)
        logger.info("Transcript saved: \(url.lastPathComponent, privacy: .private)")
        return url
    }

    /// Save a protocol to a Markdown file.
    ///
    /// `basename` is the job's precomputed, meeting-start-anchored stem (shared
    /// with the transcript and audio artifacts); the `.md` extension is appended.
    ///
    /// Opens no security scope, as for `saveTranscript`.
    ///
    /// - Returns: URL of the saved file
    static func saveProtocol(_ markdown: String, basename: String, dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(basename).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        // Protocol markdown summarises the meeting — restrict to owner-only.
        try FileManager.default.restrictToOwner(url)
        logger.info("Protocol saved: \(url.lastPathComponent, privacy: .private)")
        return url
    }

    private static let filenameFormatter = DateFormatter.filenameStamp("yyyyMMdd_HHmm")

    /// Sanitize a title into a safe filename slug (path-traversal safe).
    /// Falls back to `"meeting"` if no allowed characters remain.
    private static let slugAllowed = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_"))

    static func sanitizeSlug(_ title: String) -> String {
        let slug = String(stripExistingTimestampPrefix(title)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .filter { slugAllowed.contains($0) }
            .map(Character.init))
        return slug.isEmpty ? "meeting" : slug
    }

    /// Re-importing a previously-processed recording feeds its slug-based stem
    /// back as a title (e.g. `20260516_1319_20260503_174538`). `filename` would
    /// then prepend ANOTHER `yyyyMMdd_HHmm_` → compounding-prefix loop on every
    /// reprocess. Strip a leading `yyyyMMdd_HHmm[ss]_` so the slug stays
    /// idempotent across reprocesses.
    static func stripExistingTimestampPrefix(_ title: String) -> String {
        let patterns = [#"^\d{8}_\d{6}_"#, #"^\d{8}_\d{4}_"#]
        var result = title
        // Apply repeatedly — input may already contain multiple compounded layers
        // from earlier buggy runs; one call should normalize the worst case.
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                if let range = result.range(of: pattern, options: .regularExpression) {
                    result.removeSubrange(range)
                    changed = true
                }
            }
        }
        return result.isEmpty ? title : result
    }

    /// Build a filesystem basename: `{yyyyMMdd_HHmm}_{slug}[_{shortID}]`.
    ///
    /// The timestamp is anchored on `startTime` (the meeting start) so the name
    /// reflects when the meeting happened, not when the pipeline processed it.
    /// The trailing `shortID` (when non-empty) is a per-job collision guard so
    /// two same-title meetings can't clobber each other's files. Empty
    /// components are dropped, so `shortID: ""` yields the plain
    /// `{yyyyMMdd_HHmm}_{slug}` shape.
    static func basename(title: String, startTime: Date, shortID: String) -> String {
        let date = filenameFormatter.string(from: startTime)
        let slug = sanitizeSlug(title)
        return [date, slug, shortID].filter { !$0.isEmpty }.joined(separator: "_")
    }

    /// Generate a filename: `{yyyyMMdd_HHmm}_{slug}.{ext}`, stamped with the
    /// current time and no collision suffix. Thin wrapper over `basename`.
    static func filename(title: String, ext: String) -> String {
        "\(basename(title: title, startTime: Date(), shortID: "")).\(ext)"
    }

    /// Extract a meeting title from protocol markdown.
    ///
    /// Looks for the first top-level `#` heading. The built-in prompt asks for
    /// `# <Protocol word> - <Title>` in the protocol language, so a short label
    /// before the first dash is dropped, as is a known protocol word before a
    /// colon. Anything else is a direct title and is kept whole, including a
    /// colon or later dashes inside it.
    ///
    /// Returns `nil` if there is no usable title: no heading, a placeholder
    /// (`Untitled`, the protocol word alone), or a title still wrapped in square
    /// brackets. The model translates the template's `[Meeting Title]` into the
    /// protocol language, so no word list can cover it; a bracketed title is
    /// treated as the unfilled template and the caller keeps the timestamped name.
    static func extractTitle(from markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let raw = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            // `# Meeting Protocol -` is the label with an empty title slot, not
            // a title that happens to end in a dash.
            let header = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-–—: "))
            guard !header.isEmpty else { return nil }
            // Whatever follows the first separator is the title slot of the
            // template, even when the lead-in is too long to count as a label.
            if let tail = splitHeading(header)?.rest, isBracketed(tail) { return nil }
            return validTitle(titlePart(of: header))
        }
        return nil
    }

    private static func stripEmphasis(_ text: String) -> String {
        let emphasis = CharacterSet(charactersIn: "\"'*_`“”‘’")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: emphasis)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBracketed(_ text: String) -> Bool {
        let stripped = stripEmphasis(text)
        return stripped.hasPrefix("[") && stripped.hasSuffix("]")
    }

    private static let dashSeparators = [" - ", " – ", " — "]

    /// A heading label before the dash ("Meeting Protocol", "Besprechungsprotokoll")
    /// is at most this many words; a longer lead-in is part of the title.
    private static let maxPrefixWords = 3

    /// The heading cut at its first separator, `nil` if it has none or nothing
    /// follows it. `isDash` tells a dash from a colon.
    private static func splitHeading(_ header: String) -> (prefix: String, rest: String, isDash: Bool)? {
        let found = (dashSeparators + [": "]).compactMap { separator in
            header.range(of: separator).map { (range: $0, isDash: separator != ": ") }
        }
        guard let first = found.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else { return nil }
        let rest = header[first.range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (header[..<first.range.lowerBound].trimmingCharacters(in: .whitespaces), rest, first.isDash)
    }

    private static func titlePart(of header: String) -> String {
        guard let (prefix, rest, isDash) = splitHeading(header) else { return header }
        let isProtocolWord = protocolHeadingWords.contains(prefix.lowercased())
        let isShortLabel = isDash
            && !prefix.contains(":")
            && prefix.split(whereSeparator: \.isWhitespace).count <= maxPrefixWords
        return isProtocolWord || isShortLabel ? rest : header
    }

    private static func validTitle(_ raw: String) -> String? {
        let title = stripEmphasis(raw)
        if isBracketed(title) { return nil }
        let lower = title.lowercased()
        guard !title.isEmpty,
              !placeholderTitles.contains(lower),
              !protocolHeadingWords.contains(lower)
        else { return nil }
        return title
    }

    /// The word a protocol heading opens with, in the languages the Settings
    /// picker offers most. Alone it is a heading without a title.
    private static let protocolHeadingWords: Set<String> = [
        "meeting protocol", "protocol", "meeting minutes", "minutes",
        "besprechungsprotokoll", "sitzungsprotokoll", "meeting-protokoll", "protokoll",
        "protokol rapat",
    ]

    private static let placeholderTitles: Set<String> = [
        "meeting title", "title", "titel", "titel des meetings", "titel der besprechung",
        "untitled", "unbenannt", "unknown", "none", "n/a", "tbd",
    ]

    /// Longest slug `toSnakeCase` returns, in UTF-8 bytes. A file name component
    /// holds at most 255 bytes on APFS; the longest artifact suffix
    /// (`_app_16k.wav`, `_naming.json`) and a `_<shortID>` collision guard still
    /// have to fit after the slug.
    static let maxSlugBytes = 100

    /// Convert arbitrary text (e.g. an AI meeting title) to a path-safe
    /// snake_case slug: lowercase alphanumerics, every other run of characters
    /// collapsed to one underscore, no leading or trailing underscore, cut to
    /// `maxSlugBytes` on a character boundary. Returns `nil` if nothing
    /// alphanumeric remains, so the caller can keep the timestamped name rather
    /// than file every such meeting under one generic word.
    static func toSnakeCase(_ text: String) -> String? {
        var result = ""
        var pendingSeparator = false
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator && !result.isEmpty { result.append("_") }
                pendingSeparator = false
                result.append(String(scalar).lowercased())
            } else {
                pendingSeparator = true
            }
        }

        var capped = ""
        for character in result {
            guard capped.utf8.count + character.utf8.count <= maxSlugBytes else { break }
            capped.append(character)
        }
        while capped.hasSuffix("_") {
            capped.removeLast()
        }
        return capped.isEmpty ? nil : capped
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
    case generationTimedOut(Int)
    case protocolTruncated

    var errorDescription: String? {
        switch self {
        #if !APPSTORE
            case let .cliNotFound(bin): "'\(bin)' CLI not found. Install: npm install -g @anthropic-ai/claude-code"

            case let .cliFailed(code, stderr): "Claude CLI exited with code \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"

            case .timeout: "Claude CLI took too long (>10 min)"
        #endif

        case .emptyProtocol: "Meeting notes are empty. Tip: Test manually: echo Hello | claude --print"

        case let .httpError(code, body): "HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"

        case let .connectionFailed(reason): "Connection failed: \(reason)"

        case let .generationTimedOut(seconds): "Meeting notes generation timed out after \(seconds)s. The LLM endpoint is stuck or too slow — try a smaller model or shorter context."

        case .protocolTruncated: "Meeting notes were cut off before finishing (model hit its output/context limit). Raise the limit or shorten the transcript."
        }
    }
}
