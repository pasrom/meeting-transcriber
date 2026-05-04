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
    /// Shared formatter — `ISO8601DateFormatter` init is non-trivial, so we
    /// keep one instance for both the header timestamp and per-entry timestamps.
    private static let formatter = ISO8601DateFormatter()

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

    /// Reads the last `windowSeconds` of unified-log entries for our subsystems
    /// and writes them to `outputURL`. Returns the number of log entries
    /// written (excluding the header). Prefers the persistent file source
    /// when available, falls back to `OSLogStore`.
    @available(macOS 12, *)
    static func export(
        to outputURL: URL,
        appVersion: String,
        commit: String,
        macOSVersion: String,
        settings: [String: String],
        windowSeconds: TimeInterval = 1800,
    ) throws -> Int {
        let todayFile = PersistentDiagnosticLog.logDirectory
            .appendingPathComponent(PersistentDiagnosticLog.logFileName(for: Date()))
        if FileManager.default.fileExists(atPath: todayFile.path) {
            return try exportFromFile(
                sourceFile: todayFile,
                to: outputURL,
                windowSeconds: windowSeconds,
                appVersion: appVersion,
                commit: commit,
                macOSVersion: macOSVersion,
                settings: settings,
            )
        }
        return try exportFromOSLogStore(
            to: outputURL,
            windowSeconds: windowSeconds,
            appVersion: appVersion,
            commit: commit,
            macOSVersion: macOSVersion,
            settings: settings,
        )
    }

    /// File-source path: read the persistent diagnostic-log file, tail-filter
    /// to entries within `windowSeconds`, write header + body to `outputURL`.
    /// Returns the number of body lines (excludes header).
    static func exportFromFile(
        sourceFile: URL,
        to outputURL: URL,
        windowSeconds: TimeInterval,
        appVersion: String,
        commit: String,
        macOSVersion: String,
        settings: [String: String],
    ) throws -> Int {
        let header = makeHeader(
            appVersion: appVersion, commit: commit,
            macOSVersion: macOSVersion, settings: settings,
        )

        let raw = (try? String(contentsOf: sourceFile, encoding: .utf8)) ?? ""
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        let kept = raw.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            // Lines without a parseable syslog timestamp (continuation lines,
            // prelude noise) are kept — only filter when we can identify
            // they're definitely older than the cutoff.
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
        windowSeconds: TimeInterval,
        appVersion: String,
        commit: String,
        macOSVersion: String,
        settings: [String: String],
    ) throws -> Int {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-windowSeconds))
        let predicate = NSPredicate(
            format: "subsystem CONTAINS 'com.meetingtranscriber'",
        )
        let entries = try store.getEntries(at: position, matching: predicate)

        var lines: [String] = [makeHeader(
            appVersion: appVersion, commit: commit,
            macOSVersion: macOSVersion, settings: settings,
        )]
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
    /// `Date` in the current year. Returns nil for lines without that prefix
    /// (e.g. multi-line continuations). Locale-pinned to `en_US_POSIX` so
    /// `log stream` output is parsed consistently regardless of user locale.
    static func parseSyslogDate(_ line: String) -> Date? {
        guard line.count >= 15 else { return nil }
        let prefix = String(line.prefix(15))
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        guard let parsed = fmt.date(from: prefix) else { return nil }
        // The parsed date defaults to year 2000; rebuild with current year.
        var components = Calendar.current.dateComponents(
            [.month, .day, .hour, .minute, .second], from: parsed,
        )
        components.year = Calendar.current.component(.year, from: Date())
        return Calendar.current.date(from: components)
    }
}
