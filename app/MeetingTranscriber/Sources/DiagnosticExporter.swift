import Foundation
import OSLog

/// Reads recent unified-log entries for the app's subsystems and writes them
/// to a shareable `.log` file with a header describing the app build state.
/// Used by Settings → Advanced → "Export Diagnostics…".
enum DiagnosticExporter {
    /// Shared formatter — `ISO8601DateFormatter` init is non-trivial, so we
    /// keep one instance for both the header timestamp and per-entry timestamps
    /// in `export(...)`.
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
    /// written (excluding the header). Throws on store-open or write failures.
    @available(macOS 12, *)
    static func export(
        to outputURL: URL,
        appVersion: String,
        commit: String,
        macOSVersion: String,
        settings: [String: String],
        windowSeconds: TimeInterval = 1800,
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
}
