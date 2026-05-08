import Foundation
import os.log

private let logger = Logger(
    subsystem: AppPaths.logSubsystem, category: "PersistentDiagnosticLog",
)

/// Sliding-window restart policy for the `log stream` subprocess. Pure value
/// type so it can be exhaustively unit-tested without spawning processes.
/// `Streamer` keeps a list of recent failure timestamps and asks the policy
/// after each unexpected exit whether to relaunch (and how long to wait).
struct RestartPolicy: Equatable {
    /// Maximum failures allowed within `window` before `decide` returns `.giveUp`.
    let maxFailuresInWindow: Int
    /// Sliding window over which failures are counted, in seconds.
    let window: TimeInterval
    /// Cap on the exponential backoff (`2^count` seconds) between restarts.
    let maxBackoff: TimeInterval

    static let `default` = Self(
        maxFailuresInWindow: 5,
        window: 60,
        maxBackoff: 30,
    )

    enum Decision: Equatable {
        case restart(after: TimeInterval)
        case giveUp
    }

    /// Filters `recentFailures` to entries newer than `now - window`, then
    /// returns `.giveUp` if too many remain or `.restart` with exponential
    /// backoff (1 s, 2 s, 4 s, …, clamped to `maxBackoff`).
    func decide(now: Date, recentFailures: [Date]) -> Decision {
        let cutoff = now.addingTimeInterval(-window)
        let inWindow = recentFailures.filter { $0 >= cutoff }
        if inWindow.count >= maxFailuresInWindow {
            return .giveUp
        }
        let delay = min(pow(2.0, Double(inWindow.count)), maxBackoff)
        return .restart(after: delay)
    }
}

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
        /// `init(...)` opens today's file, `start()` launches the subprocess
        /// and pipes its stdout into the file, `stop()` terminates the process
        /// and closes the file handle. The file rotates lazily when
        /// `append(_:)` first sees a new UTC day. If the subprocess exits
        /// unexpectedly, the streamer relaunches it according to
        /// `restartPolicy`; once the policy gives up, `isRunning` flips to
        /// false and no further data is collected until the next `start()`.
        ///
        /// Gated `#if !APPSTORE` because `Process` is forbidden under sandbox.
        /// The App Store variant falls back to `OSLogStore` in `DiagnosticExporter`.
        ///
        /// `@unchecked Sendable` because `Pipe.readabilityHandler` is invoked
        /// on an arbitrary background queue and the `terminationHandler`
        /// fires on Foundation's private Process queue. All state mutations
        /// (`isRunning`, `recentFailures`, `process`, `pipe`) go through
        /// `restartQueue` to serialise start, stop, unexpected-exit, and the
        /// delayed relaunch with respect to each other. `append`'s file-handle
        /// writes stay outside the queue — the OS serialises readability
        /// callbacks per pipe and the day-rotation tests exercise that path
        /// directly without spawning a real subprocess.
        final class Streamer: @unchecked Sendable {
            private var process = Process()
            private var pipe = Pipe()
            private let logDirectory: URL
            private let now: () -> Date
            private var logFileHandle: FileHandle
            private var openedDateString: String
            private var _isRunning = false
            /// Thread-safe view of the running flag. External readers (tests,
            /// `AppState`) hit the queue-synchronised accessor; internal code
            /// already runs on `restartQueue` and uses `_isRunning` directly.
            var isRunning: Bool {
                restartQueue.sync { _isRunning }
            }

            private let logExecutable: URL
            private let logArguments: [String]
            private let restartPolicy: RestartPolicy
            private var recentFailures: [Date] = []
            private let restartQueue = DispatchQueue(
                label: "com.meetingtranscriber.persistent-log-streamer.restart",
            )

            init(
                logDirectory: URL = PersistentDiagnosticLog.logDirectory,
                now: @escaping () -> Date = { Date() },
                restartPolicy: RestartPolicy = .default,
                logExecutable: URL = URL(fileURLWithPath: "/usr/bin/log"),
                logArguments: [String] = [
                    "stream",
                    "--predicate", "subsystem CONTAINS 'com.meetingtranscriber'",
                    "--style", "syslog",
                    "--info",
                ],
            ) throws {
                self.logDirectory = logDirectory
                self.now = now
                self.restartPolicy = restartPolicy
                self.logExecutable = logExecutable
                self.logArguments = logArguments
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
                try restartQueue.sync {
                    guard !_isRunning else { return }
                    recentFailures.removeAll()
                    try launchProcess()
                    _isRunning = true
                }
            }

            /// Must be called on `restartQueue`. Recreates `process`/`pipe`
            /// (Process is single-shot — once exited, can't be relaunched).
            private func launchProcess() throws {
                process = Process()
                pipe = Pipe()
                process.executableURL = logExecutable
                process.arguments = logArguments
                process.standardOutput = pipe
                process.standardError = pipe
                process.terminationHandler = { [weak self] proc in
                    self?.handleProcessExit(
                        reason: proc.terminationReason,
                        status: proc.terminationStatus,
                    )
                }

                let handle = pipe.fileHandleForReading
                handle.readabilityHandler = { [weak self] fh in
                    let data = fh.availableData
                    guard !data.isEmpty else { return }
                    self?.append(data)
                }

                try process.run()
                logger.info(
                    "persistent_log_streamer_started pid=\(self.process.processIdentifier, privacy: .public)",
                )
            }

            private func handleProcessExit(
                reason: Process.TerminationReason, status: Int32,
            ) {
                restartQueue.async { [weak self] in
                    guard let self else { return }
                    // User-initiated stop already flipped `_isRunning` and
                    // detached the handler, so any straggling callback is a
                    // no-op.
                    guard self._isRunning else { return }

                    let now = self.now()
                    let cutoff = now.addingTimeInterval(-self.restartPolicy.window)
                    self.recentFailures = self.recentFailures.filter { $0 >= cutoff }

                    switch self.restartPolicy.decide(
                        now: now, recentFailures: self.recentFailures,
                    ) {
                    case .giveUp:
                        logger.error(
                            "persistent_log_streamer_gave_up failures=\(self.recentFailures.count, privacy: .public)",
                        )
                        self._isRunning = false

                    case let .restart(delay):
                        logger.warning(
                            "persistent_log_streamer_restarting reason=\(reason.rawValue, privacy: .public) status=\(status, privacy: .public) delay=\(delay, privacy: .public)",
                        )
                        self.recentFailures.append(now)
                        self.restartQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, self._isRunning else { return }
                            do {
                                try self.launchProcess()
                            } catch {
                                logger.error(
                                    "persistent_log_streamer_relaunch_failed error=\(error.localizedDescription, privacy: .public)",
                                )
                                self._isRunning = false
                            }
                        }
                    }
                }
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
                restartQueue.sync {
                    guard _isRunning else { return }
                    _isRunning = false
                    // Drop the termination handler before terminate so the
                    // resulting exit isn't mistaken for an unexpected crash —
                    // belt-and-suspenders alongside the `isRunning` check in
                    // `handleProcessExit`.
                    process.terminationHandler = nil
                    process.terminate()
                    // Detach the readability callback before closing the file
                    // handle — otherwise a late callback could write to a
                    // recycled FD.
                    pipe.fileHandleForReading.readabilityHandler = nil
                    try? logFileHandle.close()
                    logger.info("persistent_log_streamer_stopped")
                }
            }

            deinit {
                // ARC guarantees no other method is executing against `self`
                // once deinit starts, so `_isRunning` is race-free here.
                if _isRunning {
                    process.terminationHandler = nil
                    process.terminate()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    try? logFileHandle.close()
                }
            }
        }
    #endif
}
