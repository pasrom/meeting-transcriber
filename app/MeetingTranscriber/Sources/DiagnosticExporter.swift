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

    /// Shared formatter — `ISO8601DateFormatter` init is non-trivial, so we
    /// keep one instance for both the header timestamp and per-entry timestamps.
    private static let formatter = ISO8601DateFormatter()

    /// Cached `DateFormatter` for syslog-style line prefixes (`MMM d HH:mm:ss`).
    /// Reused for every line in `exportFromFile`'s filter loop — at thousands
    /// of lines the per-call allocation cost matters. Locale-pinned to
    /// `en_US_POSIX` so output of `log stream` is parsed consistently.
    private static let syslogFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
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
    /// and writes them to `outputURL`. Returns the number of log entries
    /// written (excluding the header). Prefers the persistent file source
    /// when available, falls back to `OSLogStore`.
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
        let kept: [Substring] = raw.isEmpty
            ? []
            : raw.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                // Lines without a parseable syslog timestamp (continuation lines,
                // prelude noise, blanks) are kept — only filter when we can
                // identify them as definitely older than the cutoff.
                guard let lineDate = parseSyslogDate(String(line)) else { return true }
                return lineDate >= cutoff
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

    /// Parses `syslog` style line prefix `Mmm d HH:mm:ss` (15 chars) to a
    /// `Date`. Returns nil for lines without that prefix (e.g. multi-line
    /// continuations). Uses the cached `syslogFormatter` — avoids per-call
    /// DateFormatter allocation when filtering thousands of lines.
    ///
    /// Year inference: syslog format omits the year. Default to the current
    /// year, but if the resulting date is more than ~30 days in the future
    /// relative to `now`, we're likely parsing a December log on a January
    /// day — in that case roll back one year.
    static func parseSyslogDate(_ line: String, now: Date = Date()) -> Date? {
        guard line.count >= 15 else { return nil }
        let prefix = String(line.prefix(15))
        guard let parsed = syslogFormatter.date(from: prefix) else { return nil }
        var components = Calendar.current.dateComponents(
            [.month, .day, .hour, .minute, .second], from: parsed,
        )
        let nowYear = Calendar.current.component(.year, from: now)
        components.year = nowYear
        guard let candidate = Calendar.current.date(from: components) else { return nil }
        // If the candidate is far in the future, the log line is from the
        // previous year (year-boundary export, e.g. Jan 1 reading Dec 31).
        if candidate.timeIntervalSince(now) > 30 * 86400 {
            components.year = nowYear - 1
            return Calendar.current.date(from: components)
        }
        return candidate
    }
}
