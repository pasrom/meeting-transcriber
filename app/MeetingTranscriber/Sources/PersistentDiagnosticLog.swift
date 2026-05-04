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

    /// Delete diagnostic-log files older than `retentionDays`. Non-matching files
    /// (anything not `diagnostics-YYYY-MM-DD.log`) are left alone. Safe to call
    /// multiple times; idempotent. Silently no-ops if the directory is missing.
    static func cleanup(
        in directory: URL = logDirectory,
        retentionDays: Int = defaultRetentionDays,
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
        ) else {
            return
        }
        for url in entries {
            guard isOurLogFile(url.lastPathComponent) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date,
                  isExpired(modifiedAt: mtime, retentionDays: retentionDays)
            else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
