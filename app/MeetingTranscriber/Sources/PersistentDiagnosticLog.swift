import Foundation

/// Manages a rolling on-disk mirror of `os.Logger` output for the
/// `com.meetingtranscriber*` subsystems. Files are written by a background
/// `log stream` subprocess (see `Streamer`) and rotated daily.
/// `DiagnosticExporter` reads from these files when present, so users can
/// reproduce a bug, wait, and still export hours-old logs — beyond the
/// macOS unified-log retention window for `.info`-level entries.
enum PersistentDiagnosticLog {
    /// `~/Library/Logs/MeetingTranscriber/` — Apple convention, picked up
    /// by Console.app's "Log Reports" tab and not auto-cleaned by macOS.
    static var logDirectory: URL {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MeetingTranscriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }

    /// Default retention in days. Older files are deleted on app launch.
    static let defaultRetentionDays = 30

    /// File name for a given date, rotating daily. UTC so the file boundary
    /// is stable regardless of where the user travels.
    static func logFileName(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return "diagnostics-\(fmt.string(from: date)).log"
    }

    /// True when the file's mtime is older than `retentionDays` ago.
    static func isExpired(modifiedAt date: Date, retentionDays: Int) -> Bool {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        return date < cutoff
    }

    /// Filter for files we own — only delete things matching our naming pattern,
    /// never random files a user dropped in the directory.
    static func isOurLogFile(_ name: String) -> Bool {
        let pattern = #"^diagnostics-\d{4}-\d{2}-\d{2}\.log$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }
}
