import Foundation
import os.log

private let logger = Logger(
    subsystem: AppPaths.logSubsystem, category: "PersistentDiagnosticLog",
)

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

    /// Cached file-name formatter. UTC so the file boundary is stable
    /// regardless of where the user travels.
    private static let fileNameFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt
    }()

    /// File name for a given date, rotating daily.
    static func logFileName(for date: Date) -> String {
        "diagnostics-\(fileNameFormatter.string(from: date)).log"
    }

    /// UTC date stamp used to detect day boundaries — same formatter as filenames.
    static func dateString(for date: Date) -> String {
        fileNameFormatter.string(from: date)
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

    #if !APPSTORE
        /// Convenience: open today's log file as the stream target. Returns the
        /// running streamer so the caller can stop it on app shutdown.
        @discardableResult
        static func startForToday() throws -> Streamer {
            let streamer = try Streamer()
            try streamer.start()
            return streamer
        }
    #endif

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

    #if !APPSTORE
        /// Wraps a running `log stream` subprocess that mirrors our subsystems
        /// to a local file. Lifetime is owned by `AppState`. Lifecycle:
        /// `init(logDirectory:now:)` opens today's file, `start()` launches the
        /// subprocess and pipes its stdout into the file, `stop()` terminates
        /// the process and closes the file handle. The file rotates lazily
        /// when `append(_:)` first sees a new UTC day.
        ///
        /// Gated `#if !APPSTORE` because `Process` is forbidden under sandbox.
        /// The App Store variant falls back to `OSLogStore` in `DiagnosticExporter`.
        ///
        /// `@unchecked Sendable` because `Pipe.readabilityHandler` is invoked on
        /// an arbitrary background queue and Swift 6 requires the captured
        /// `[weak self]` to be Sendable. Internal mutable state (`logFileHandle`,
        /// `openedDateString`, `isRunning`) is touched only by `start()` and
        /// the readability handler, which the OS serialises by way of issuing
        /// callbacks one-at-a-time per pipe — the class is externally
        /// single-threaded by contract.
        final class Streamer: @unchecked Sendable {
            private let process = Process()
            private let pipe = Pipe()
            private let logDirectory: URL
            private let now: () -> Date
            private var logFileHandle: FileHandle
            private var openedDateString: String
            private var isRunning = false

            init(
                logDirectory: URL = PersistentDiagnosticLog.logDirectory,
                now: @escaping () -> Date = { Date() },
            ) throws {
                self.logDirectory = logDirectory
                self.now = now
                let date = now()
                let target = logDirectory.appendingPathComponent(logFileName(for: date))
                let fm = FileManager.default
                if !fm.fileExists(atPath: target.path) {
                    fm.createFile(atPath: target.path, contents: nil)
                }
                self.logFileHandle = try FileHandle(forWritingTo: target)
                try self.logFileHandle.seekToEnd()
                self.openedDateString = PersistentDiagnosticLog.dateString(for: date)
            }

            func start() throws {
                guard !isRunning else { return }
                process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                process.arguments = [
                    "stream",
                    "--predicate", "subsystem CONTAINS 'com.meetingtranscriber'",
                    "--style", "syslog",
                    "--info",
                ]
                process.standardOutput = pipe
                process.standardError = pipe

                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = { [weak self] fh in
                    let data = fh.availableData
                    guard !data.isEmpty else { return }
                    self?.append(data)
                }

                try process.run()
                isRunning = true
                logger.info(
                    "persistent_log_streamer_started pid=\(self.process.processIdentifier, privacy: .public)",
                )
            }

            /// Append `data` to the current day's file, rotating to the new
            /// day's file first if the UTC date has changed since the handle
            /// was opened. Test seam: also called by the readability handler.
            func append(_ data: Data) {
                rotateIfNeeded()
                try? logFileHandle.write(contentsOf: data)
            }

            private func rotateIfNeeded() {
                let date = now()
                let today = PersistentDiagnosticLog.dateString(for: date)
                guard today != openedDateString else { return }
                let newURL = logDirectory.appendingPathComponent(logFileName(for: date))
                let fm = FileManager.default
                if !fm.fileExists(atPath: newURL.path) {
                    fm.createFile(atPath: newURL.path, contents: nil)
                }
                // Open the new handle before closing the old one — if open
                // fails (disk full, permissions), keep writing to the old
                // file rather than silently dropping every subsequent entry.
                guard let newHandle = try? FileHandle(forWritingTo: newURL) else { return }
                _ = try? newHandle.seekToEnd()
                try? logFileHandle.close()
                logFileHandle = newHandle
                openedDateString = today
                logger.info("persistent_log_streamer_rotated date=\(today, privacy: .public)")
            }

            func stop() {
                guard isRunning else { return }
                process.terminate()
                // Detach the readability callback before closing the file
                // handle — otherwise a late callback could write to a
                // recycled FD.
                pipe.fileHandleForReading.readabilityHandler = nil
                try? logFileHandle.close()
                isRunning = false
                logger.info("persistent_log_streamer_stopped")
            }

            deinit {
                if isRunning {
                    process.terminate()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    try? logFileHandle.close()
                }
            }
        }
    #endif
}
