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
    /// `exportFromFile`'s filter loop: at thousands of lines the per-call
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

    /// Reads the last `windowSeconds` of unified-log entries for our subsystems
    /// and writes them to `outputURL`. Returns the number of body lines
    /// written (excluding the header): for the file source that counts the
    /// continuation lines of a multi-line entry too. Prefers the persistent
    /// file source when available, falls back to `OSLogStore`.
    @available(macOS 12, *)
    static func export(
        to outputURL: URL,
        info: HeaderInfo,
        windowSeconds: TimeInterval = 1800,
    ) throws -> Int {
        let todayFile = PersistentDiagnosticLog.logDirectory
            .appendingPathComponent(PersistentDiagnosticLog.logFileName(for: Date()))
        if FileManager.default.fileExists(atPath: todayFile.path) {
            return try exportFromFile(
                sourceFile: todayFile,
                to: outputURL,
                info: info,
                windowSeconds: windowSeconds,
            )
        }
        return try exportFromOSLogStore(
            to: outputURL,
            info: info,
            windowSeconds: windowSeconds,
        )
    }

    /// File-source path: read the persistent diagnostic-log file, tail-filter
    /// to entries within `windowSeconds`, write header + body to `outputURL`.
    /// Returns the number of body lines (excludes header).
    static func exportFromFile(
        sourceFile: URL,
        to outputURL: URL,
        info: HeaderInfo,
        windowSeconds: TimeInterval,
    ) throws -> Int {
        let header = makeHeader(info)

        let raw = (try? String(contentsOf: sourceFile, encoding: .utf8)) ?? ""
        let cutoff = Date().addingTimeInterval(-windowSeconds)
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
        var keepingEntry = true
        let kept: [Substring] = raw.isEmpty
            ? []
            : raw.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                if let lineDate = parseLineDate(line) {
                    keepingEntry = lineDate >= cutoff
                }
                return keepingEntry
            }
        let body = kept.joined(separator: "\n")
        try (header + "\n" + body).write(to: outputURL, atomically: true, encoding: .utf8)
        return kept.count
    }

    /// OSLogStore-source path (legacy / App Store fallback).
    @available(macOS 12, *)
    static func exportFromOSLogStore(
        to outputURL: URL,
        info: HeaderInfo,
        windowSeconds: TimeInterval,
    ) throws -> Int {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-windowSeconds))
        let predicate = NSPredicate(
            format: "subsystem CONTAINS 'com.meetingtranscriber'",
        )
        let entries = try store.getEntries(at: position, matching: predicate)

        var lines: [String] = [makeHeader(info)]
        var count = 0
        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            let timestamp = formatter.string(from: log.date)
            let line = "\(timestamp) [\(log.level.rawValue)] " +
                "\(log.subsystem)/\(log.category): \(log.composedMessage)"
            lines.append(line)
            count += 1
        }

        try lines.joined(separator: "\n").write(to: outputURL, atomically: true, encoding: .utf8)
        return count
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
