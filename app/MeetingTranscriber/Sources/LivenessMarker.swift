import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LivenessMarker")

/// How the previous run of this bundle ended, as far as the next launch can
/// tell from the marker it left or did not leave.
enum PreviousExit: Equatable {
    /// No marker: the previous run quit through AppKit, or the app has never
    /// run on this machine. The two cannot be told apart and need not be.
    case clean

    /// A marker whose process is alive: a second instance of this bundle, or
    /// this very run's own marker read by a later `inspect`. Not a crash
    /// either way.
    case stillRunning(pid: pid_t)

    /// A marker whose process is gone: the previous run ended without a quit.
    /// A crash, a Force Quit, a `kill`, or the power going. `lastAlive` is
    /// the last heartbeat, so nothing was watching for meetings from at most
    /// `LivenessMarker.heartbeatInterval` after it until this launch.
    case unclean(lastAlive: Date)
}

/// A file that exists exactly while a run of the app is alive (issue #703).
///
/// Written at launch, touched every `heartbeatInterval` while running, and
/// removed by a clean quit. A launch that finds one belonging to a dead
/// process knows the previous run ended without quitting, which is the one
/// thing a menu bar app cannot otherwise tell: gone looks exactly like idle,
/// and an app that is not running records nothing and warns nobody.
///
/// Deliberately a second signal beside the recording marker
/// (`RecordingFileSuffix.inProgress`). That one is per recording, written in
/// `DualSourceRecorder.start()` and removed in `stop()`, so it only ever
/// exists while a recording is in flight: an app that dies while idle, which
/// is how issue #700 ended, leaves no recording marker at all. It also lives
/// in a different directory on purpose. The staging dir is scanned for crash
/// signatures by name, and that scan has a history of reading leftovers as
/// interrupted recordings (see the note on `RecordingFileSuffix.inProgress`),
/// so nothing new may be dropped there.
///
/// What it cannot tell apart: a crash from a Force Quit, a `kill`, or a power
/// loss. All of them end the process without AppKit's termination path, so
/// all of them leave the marker. That is the right side to err on: every one
/// of them is a window in which no meeting was recorded, and a user who did
/// the killing loses nothing by being told the window.
enum LivenessMarker {
    /// How often the marker is touched while the app runs. Bounds how stale
    /// the reported `lastAlive` can be; a minute is fine for a message about
    /// meetings and costs one `utimes` call per minute.
    static let heartbeatInterval: TimeInterval = 60

    /// Read what the marker says about the run that wrote it. `arm` calls
    /// this before it writes, which is the read that matters; a later call
    /// finds this run's own marker and reports it as `.stillRunning`.
    ///
    /// `isAlive` says whether the recorded process is a running instance of
    /// this bundle. Injected so the verdict is testable without a second
    /// process; production asks AppKit. It is not asked about a marker that
    /// cannot be parsed: there is no process to ask about, and a run left the
    /// file behind either way.
    static func inspect(
        at url: URL = AppPaths.livenessMarker,
        isAlive: (pid_t) -> Bool = isRunningInstance,
    ) -> PreviousExit {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return .clean }
        let lastAlive = (attributes[.modificationDate] as? Date) ?? Date()
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           isAlive(pid) {
            return .stillRunning(pid: pid)
        }
        return .unclean(lastAlive: lastAlive)
    }

    /// Record `pid` as the running instance. Creates the data directory on the
    /// first launch, which has none yet.
    static func write(pid: pid_t = getpid(), at url: URL = AppPaths.livenessMarker) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("\(pid)".utf8).write(to: url, options: .atomic)
    }

    /// Move the marker's modification time to now. A touch, not a rewrite: it
    /// cannot bring back a marker a concurrent quit has just removed.
    static func heartbeat(at url: URL = AppPaths.livenessMarker) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// The clean-quit half: remove the marker, but only while it still names
    /// this process. A second instance of this bundle takes the marker over
    /// when it launches (`arm` writes its own PID), and from then on it is
    /// the run whose crash the file must witness; the first instance quitting
    /// cleanly has to leave it alone. An unreadable marker is left alone too:
    /// this process writes its own atomically, so garbage there is not ours.
    static func release(at url: URL = AppPaths.livenessMarker) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) == getpid() else { return }
        remove(at: url)
    }

    /// Unconditional removal, for a marker that is known not to belong to a
    /// live run. Safe when there is nothing to remove.
    static func remove(at url: URL = AppPaths.livenessMarker) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The heartbeat and the two observers, kept for the life of the process.
    /// Static because the marker describes the process, not any object in
    /// it. A second `arm` replaces them rather than adding to them:
    /// production arms once, tests arm per case.
    @MainActor private static var heartbeatTimer: (any DispatchSourceTimer)?
    @MainActor private static var terminateObserver: (any NSObjectProtocol)?
    @MainActor private static var wakeObserver: (any NSObjectProtocol)?

    /// Read what the previous run left, then take the marker over for this
    /// run: write it, start the heartbeat, and release it again when AppKit
    /// terminates the app. One call rather than `inspect` followed by a
    /// separate arm, because the order is load-bearing and nothing else
    /// guards it: an inspect after the write finds this run's own marker.
    /// Call it before anything else is constructed, so a crash inside launch
    /// itself still leaves a marker behind.
    ///
    /// The terminate observer is registered with no queue so it runs
    /// synchronously on the thread that posts `willTerminateNotification`.
    /// `terminate(_:)` calls `exit` as soon as the notification has been
    /// delivered, so a handler that hops to another queue may never run.
    @MainActor
    static func arm(
        at url: URL = AppPaths.livenessMarker,
        heartbeat interval: TimeInterval = heartbeatInterval,
        isAlive: (pid_t) -> Bool = isRunningInstance,
    ) -> PreviousExit {
        let previous = inspect(at: url, isAlive: isAlive)
        do {
            try write(at: url)
        } catch {
            // A run that cannot write its marker is reported as clean next
            // time. Logged rather than surfaced: the user cannot act on it,
            // and every recording path would already be failing on the same
            // directory. A dead marker the write could not replace goes too,
            // or every later launch reposts the same notice with a window
            // that never ends. A live instance's marker is not ours to drop.
            logger.error("liveness_marker_write_failed error=\(error.localizedDescription, privacy: .public)")
            if case .unclean = previous { remove(at: url) }
            return previous
        }

        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        // `@Sendable` is load-bearing, not decoration. This function is
        // `@MainActor`, so a plain closure literal here inherits that
        // isolation, and the block parameter it is handed to is not
        // `@Sendable`, so nothing strips it: the first tick on the utility
        // queue then fails Swift 6's runtime isolation check and traps. That
        // was a crash one minute into every launch, caught by the test that
        // waits for a real tick and by nothing else.
        timer.setEventHandler { @Sendable in heartbeat(at: url) }
        timer.resume()
        heartbeatTimer = timer

        // A DispatchTime timer does not run while the machine sleeps, so
        // after a night with the lid closed the last heartbeat is from the
        // evening before, and a crash shortly after waking would claim a
        // window of fifteen hours in which no meeting could have been missed.
        // Touching on wake starts the claimed window at the wake. What this
        // does not cover is App Nap throttling the timer while awake, which
        // can make the heartbeat minutes late rather than one; the notice
        // says "at about" for that reason.
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil,
        ) { @Sendable _ in
            heartbeat(at: url)
        }

        // The timer is not cancelled at termination: a heartbeat that fires
        // after the removal touches a file that is gone, which is a silent
        // no-op, and the process is about to exit.
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil,
        ) { @Sendable _ in
            release(at: url)
        }
        return previous
    }

    /// Whether `pid` is a running instance of this bundle. This process is one
    /// by definition, so a marker naming it (a second inspect after arming, or
    /// a reused process ID) is never read as a crash. For any other process
    /// the bundle check is what matters: the marker outlives its process and
    /// the kernel reuses IDs.
    private static func isRunningInstance(_ pid: pid_t) -> Bool {
        if pid == getpid() { return true }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
