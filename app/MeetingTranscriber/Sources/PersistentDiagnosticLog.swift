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

    /// The `log stream` predicate that uniquely identifies a streamer we spawned.
    /// Shared by the `Streamer` argument list and the orphan reaper so the two
    /// can never drift — the reaper kills only processes whose command line
    /// carries this exact marker, never an unrelated `log stream` a user started.
    static let streamPredicate = "subsystem CONTAINS 'com.meetingtranscriber'"

    /// Path of the `log` binary we spawn. Reused by the reaper's command match.
    static let logExecutablePath = "/usr/bin/log"

    /// PURE: from a snapshot of the process table, pick the pids of orphaned
    /// `log stream` subprocesses WE spawned that survived a crash/SIGKILL and
    /// were re-parented to launchd (PID 1). Matching is deliberately narrow:
    ///
    /// - the command must invoke our exact `log` executable, AND
    /// - the command must carry our `streamPredicate` marker (so a user's own
    ///   unrelated `log stream` is never touched), AND
    /// - the parent must be PID 1 (re-parented orphan — a live streamer of a
    ///   *running* sibling instance still has that instance as its parent and
    ///   is left alone), AND
    /// - the pid is not our own (defence-in-depth; our process isn't `log`
    ///   anyway, but never reap self).
    ///
    /// `command` is the full argv string as `ps -axo command=` renders it.
    static func orphanPids(
        processTable: [(pid: Int32, ppid: Int32, command: String)],
        ownPid: Int32,
    ) -> [Int32] {
        processTable.compactMap { entry in
            guard entry.ppid == 1 else { return nil }
            guard entry.pid != ownPid else { return nil }
            guard entry.command.contains(logExecutablePath) else { return nil }
            guard entry.command.contains(streamPredicate) else { return nil }
            return entry.pid
        }
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

        /// Effect shell for the orphan reaper. Snapshots the process table via
        /// `ps`, runs the pure `orphanPids` filter, and SIGTERMs each match.
        ///
        /// Why this exists: a crash / SIGKILL of the app leaves the `log stream`
        /// subprocess alive — `stop()`/`deinit` never run — and launchd re-parents
        /// it to PID 1. Successive launches stack up these orphans (one machine
        /// had five, the oldest days old), each holding a unified-log subscription.
        /// Call this at launch BEFORE starting a fresh streamer so the count can't
        /// grow without bound.
        ///
        /// SIGTERM is enough: `log stream` exits cleanly on it. No escalation —
        /// a process wedged hard enough to ignore TERM is rare and not worth the
        /// complexity here. Best-effort: a `ps` failure is logged and ignored.
        static func reapOrphans() {
            let victims = orphanPids(processTable: snapshotProcessTable(), ownPid: getpid())
            for pid in victims {
                logger.info("reaping orphaned log stream pid=\(pid, privacy: .public)")
                kill(pid, SIGTERM)
            }
        }

        /// Run `ps -axo pid=,ppid=,command=` and parse it into the tuple shape
        /// `orphanPids` consumes. Returns an empty table if `ps` can't be run or
        /// read — best-effort, so a `ps` failure simply reaps nothing. The `=`
        /// suffixes suppress the header row; the first two fields are numeric,
        /// the remainder (which can contain spaces) is the command.
        private static func snapshotProcessTable() -> [(pid: Int32, ppid: Int32, command: String)] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-axo", "pid=,ppid=,command="]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do {
                try proc.run()
            } catch {
                logger.error("reap_orphans_ps_failed error=\(error.localizedDescription, privacy: .public)")
                return []
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return parseProcessTable(text)
        }

        /// PURE: parse `ps -axo pid=,ppid=,command=` output into tuples. Each line
        /// is `<pid> <ppid> <command…>`; the command can contain spaces so only
        /// the first two whitespace-delimited fields are split off. Malformed or
        /// blank lines are skipped.
        static func parseProcessTable(_ text: String) -> [(pid: Int32, ppid: Int32, command: String)] {
            text.split(separator: "\n").compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3,
                      let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1])
                else { return nil }
                return (pid: pid, ppid: ppid, command: String(parts[2]))
            }
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
            private var lastLaunchAt = Date.distantPast
            /// Thread-safe view of the running flag. External readers (tests,
            /// `AppState`) hit the queue-synchronised accessor; internal code
            /// already runs on `restartQueue` and uses `_isRunning` directly.
            var isRunning: Bool {
                restartQueue.sync { _isRunning }
            }

            /// Test-only probe — true while the readabilityHandler is still
            /// subscribed to the pipe. Used to verify that EOF self-detach
            /// fires after the subprocess exits. Queue-synced for symmetry
            /// with `isRunning` and TSan-cleanliness; the readabilityHandler
            /// itself is mutated on Foundation's pipe queue, not ours.
            var hasReadabilityHandlerForTesting: Bool {
                restartQueue.sync { pipe.fileHandleForReading.readabilityHandler != nil }
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
                logExecutable: URL = URL(fileURLWithPath: PersistentDiagnosticLog.logExecutablePath),
                logArguments: [String] = [
                    "stream",
                    "--predicate", PersistentDiagnosticLog.streamPredicate,
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
                    if data.isEmpty {
                        // Pipe writer closed (subprocess exited). Without
                        // self-detaching, Foundation reschedules this handler
                        // in a tight loop on persistent EOF — observed as
                        // ~100 % CPU on macOS 26 dev builds where `log stream`
                        // exits immediately because it now requires admin.
                        // PR #218's fail-fast stops the relaunch; this stops
                        // the pipe spin that survived it.
                        fh.readabilityHandler = nil
                        return
                    }
                    self?.append(data)
                }

                try process.run()
                lastLaunchAt = now()
                logger.info(
                    "persistent_log_streamer_started pid=\(self.process.processIdentifier, privacy: .public)",
                )
            }

            /// `log stream` started OK if it stays alive longer than this.
            /// Anything quicker is the spawn-and-die loop we're guarding
            /// against (admin-required, bad args, etc.).
            private static let failFastWindow: TimeInterval = 1.0

            private func handleProcessExit(
                reason: Process.TerminationReason, status: Int32,
            ) {
                restartQueue.async { [weak self] in
                    self?.processExitOnQueue(reason: reason, status: status)
                }
            }

            /// Body of `handleProcessExit` after the queue hop.
            private func processExitOnQueue(
                reason: Process.TerminationReason, status: Int32,
            ) {
                // User-initiated stop already flipped `_isRunning` and
                // detached the handler, so any straggling callback is a
                // no-op.
                guard _isRunning else { return }

                let now = self.now()
                // `log stream` is supposed to run forever. ANY exit inside
                // the fail-fast window — clean or not — means the binary
                // rejected its arguments or our privileges. Retrying would
                // burn CPU on the same failure.
                if now.timeIntervalSince(lastLaunchAt) < Self.failFastWindow {
                    logger.error(
                        "persistent_log_streamer_fatal_launch status=\(status, privacy: .public) reason=\(reason.rawValue, privacy: .public)",
                    )
                    _isRunning = false
                    return
                }

                let cutoff = now.addingTimeInterval(-restartPolicy.window)
                recentFailures = recentFailures.filter { $0 >= cutoff }

                switch restartPolicy.decide(now: now, recentFailures: recentFailures) {
                case .giveUp:
                    logger.error(
                        "persistent_log_streamer_gave_up failures=\(self.recentFailures.count, privacy: .public)",
                    )
                    _isRunning = false

                case let .restart(delay):
                    logger.warning(
                        "persistent_log_streamer_restarting reason=\(reason.rawValue, privacy: .public) status=\(status, privacy: .public) delay=\(delay, privacy: .public)",
                    )
                    recentFailures.append(now)
                    restartQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
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
