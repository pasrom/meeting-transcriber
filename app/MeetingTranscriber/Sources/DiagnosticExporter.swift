import Foundation
import OSLog

/// Reads recent unified-log entries for the app's subsystems and writes them
/// to a shareable `.log` file with a header describing the app build state.
/// Used by Settings → Advanced → "Export Diagnostics…".
///
/// Source preference: when `PersistentDiagnosticLog` is active and today's
/// file exists, read from that (survives longer than OSLogStore retention).
/// Otherwise fall back to `OSLogStore` (~1h window for `.info`-level entries).
enum DiagnosticExporter {
    /// Bundle of identity fields stamped into the export header. Keeps the
    /// `export(...)` parameter count manageable.
    struct HeaderInfo {
        let appVersion: String
        let commit: String
        let macOSVersion: String
        let settings: [String: String]
    }

    /// Shared formatter — `ISO8601DateFormatter` init is non-trivial.
    /// `nonisolated(unsafe)`: thread-safe for read-only use since macOS 10.9
    /// despite not being formally `Sendable`.
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    /// Length of the timestamp `log stream --style syslog` puts at the start of
    /// every entry: `2026-11-09 08:00:00.530686+0100`.
    private static let lineStampLength = 31

    /// Cached `DateFormatter` for that prefix. Reused for every line in
    /// `readExcerpt`'s filter loop: at thousands of lines the per-call
    /// allocation cost matters. Locale-pinned to `en_US_POSIX` so the fixed
    /// format parses the same under any user locale; the offset is in the
    /// line, so no time zone is assumed.
    private static let lineStampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// Build the header that prefixes every exported diagnostic file.
    /// Pure function — settings dict is stringified verbatim into `key=value`
    /// pairs, sorted alphabetically for deterministic output. No PII is
    /// expected in `settings` (UI flags only).
    static func makeHeader(
        appVersion: String,
        commit: String,
        macOSVersion: String,
        settings: [String: String],
    ) -> String {
        let pairs = settings.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let timestamp = formatter.string(from: Date())
        return """
        # MeetingTranscriber \(appVersion) (\(commit))
        # macOS \(macOSVersion)
        # exported_at=\(timestamp)
        # settings: \(pairs)
        # ---
        """
    }

    /// Build header from a `HeaderInfo` bundle.
    static func makeHeader(_ info: HeaderInfo) -> String {
        makeHeader(
            appVersion: info.appVersion,
            commit: info.commit,
            macOSVersion: info.macOSVersion,
            settings: info.settings,
        )
    }

    /// A source the export falls back to when the diagnostic log file has
    /// nothing for the window. `read` returns the entries from `since` on,
    /// oldest first; `name` identifies the source in the export. Injectable
    /// so tests never touch the real `OSLogStore`.
    struct LogSource: Sendable {
        let name: String
        let read: @Sendable (_ since: Date) throws -> [LogLine]
    }

    /// One entry from a `LogSource`: when it was logged, and the line the
    /// export writes for it.
    struct LogLine: Sendable, Equatable {
        let date: Date
        let text: String
    }

    /// The lines of the diagnostic log file that fall inside the window.
    /// `entryCount` counts only the lines that start an entry; `lines` also
    /// holds their continuation lines and any prelude before the first entry.
    struct FileExcerpt {
        let lines: [Substring]
        let entryCount: Int
    }

    /// Reads the last `windowSeconds` of unified-log entries for our subsystems
    /// and writes them to `outputURL`. Returns the number of body lines
    /// written (excluding the header): for the file source that counts the
    /// continuation lines of a multi-line entry too. Prefers the persistent
    /// file source when available, falls back to `fallback`.
    static func export(
        to outputURL: URL,
        info: HeaderInfo,
        windowSeconds: TimeInterval = 1800,
        logDirectory: URL = PersistentDiagnosticLog.logDirectory,
        fallback: LogSource = .osLogStore,
        now: Date = Date(),
    ) throws -> Int {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let todayFile = logDirectory
            .appendingPathComponent(PersistentDiagnosticLog.logFileName(for: now))
        if FileManager.default.fileExists(atPath: todayFile.path) {
            let excerpt = (try? readExcerpt(of: todayFile, cutoff: cutoff)) ?? FileExcerpt(lines: [], entryCount: 0)
            try write(body: excerpt.lines.joined(separator: "\n"), info: info, to: outputURL)
            return excerpt.lines.count
        }
        let lines = try fallback.read(cutoff)
        try write(body: lines.map(\.text).joined(separator: "\n"), info: info, to: outputURL)
        return lines.count
    }

    /// Header, then `body`. The body is joined by the caller straight from
    /// its lines, so a 50-200 MB file source is not copied line by line.
    private static func write(body: String, info: HeaderInfo, to outputURL: URL) throws {
        try (makeHeader(info) + "\n" + body).write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Reads the persistent diagnostic-log file and keeps the lines that fall
    /// inside the window starting at `cutoff`. Throws when the file cannot be
    /// read.
    static func readExcerpt(of sourceFile: URL, cutoff: Date) throws -> FileExcerpt {
        let raw = try String(contentsOf: sourceFile, encoding: .utf8)
        // omittingEmptySubsequences: false so blank lines in the source are
        // preserved verbatim — they may be intentional separators in the
        // streamed log output and dropping them changes the file shape.
        // Empty source short-circuits to no body lines (split would otherwise
        // return [""] for the empty string).
        //
        // Only a line that starts an entry carries a timestamp. Lines without
        // one (continuation lines of a multi-line message, blanks) belong to
        // the entry before them and share its fate; anything before the first
        // entry is prelude and is kept.
        guard !raw.isEmpty else { return FileExcerpt(lines: [], entryCount: 0) }
        var keepingEntry = true
        var kept: [Substring] = []
        var entryCount = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if let lineDate = parseLineDate(line) {
                keepingEntry = lineDate >= cutoff
                if keepingEntry { entryCount += 1 }
            }
            if keepingEntry { kept.append(line) }
        }
        return FileExcerpt(lines: kept, entryCount: entryCount)
    }

    /// Reads this process's entries for our subsystems from `OSLogStore`,
    /// formatted one per line. Used by the App Store build, which has no
    /// streamer, and whenever the diagnostic log file is missing.
    static func osLogStoreLines(since: Date) throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        let predicate = NSPredicate(
            format: "subsystem CONTAINS 'com.meetingtranscriber'",
        )
        return try store.getEntries(at: position, matching: predicate).compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            let timestamp = formatter.string(from: log.date)
            let text = "\(timestamp) [\(log.level.rawValue)] " +
                "\(log.subsystem)/\(log.category): \(log.composedMessage)"
            return LogLine(date: log.date, text: text)
        }
    }

    /// Parses the timestamp that starts an entry in the persistent diagnostic
    /// log (`yyyy-MM-dd HH:mm:ss.SSSSSS+ZZZZ`, the `log stream --style syslog`
    /// shape). Returns nil for lines without it, such as the continuation
    /// lines of a multi-line message.
    static func parseLineDate(_ line: some StringProtocol) -> Date? {
        // An entry starts with a digit; this skips the formatter for the
        // common non-entry lines without building a prefix string.
        guard let first = line.first, first.isASCII, first.isNumber else { return nil }
        let prefix = line.prefix(lineStampLength)
        guard prefix.count == lineStampLength else { return nil }
        return lineStampFormatter.date(from: String(prefix))
    }
}

extension DiagnosticExporter.LogSource {
    /// The production fallback: this process's entries in the unified log.
    static let osLogStore = Self(name: "OSLogStore") { since in
        try DiagnosticExporter.osLogStoreLines(since: since)
    }
}
