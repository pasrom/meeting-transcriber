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

    /// A marker whose process is alive: a second instance of this bundle, not
    /// a crash.
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

    /// Read what the previous run left, BEFORE this run arms its own marker.
    ///
    /// `isAlive` says whether the recorded process is still a running instance
    /// of this bundle. Injected so the verdict is testable without a second
    /// process; production asks AppKit. It is not asked about a marker that
    /// cannot be parsed: there is no process to ask about, and a run left the
    /// file behind either way.
    static func inspect(
        at url: URL = AppPaths.livenessMarker,
        isAlive: (pid_t) -> Bool = isAnotherInstance,
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

    /// The clean-quit half. Safe when there is nothing to remove.
    static func remove(at url: URL = AppPaths.livenessMarker) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The heartbeat, kept for the life of the process. Static because the
    /// marker describes the process, not any object in it.
    @MainActor private static var heartbeatTimer: (any DispatchSourceTimer)?

    /// Write the marker for this process, start the heartbeat, and remove the
    /// marker again when AppKit terminates the app. Call once at launch, after
    /// `inspect`, which would otherwise read this run's own marker.
    ///
    /// The observer is registered with no queue so it runs synchronously on
    /// the thread that posts `willTerminateNotification`. `terminate(_:)`
    /// calls `exit` as soon as the notification has been delivered, so a
    /// handler that hops to another queue may never run.
    @MainActor
    static func arm(at url: URL = AppPaths.livenessMarker, heartbeat interval: TimeInterval = heartbeatInterval) {
        do {
            try write(at: url)
        } catch {
            // A run that cannot write its marker is reported as clean next
            // time. Logged rather than surfaced: the user cannot act on it,
            // and every recording path would already be failing on the same
            // directory.
            logger.error("liveness_marker_write_failed error=\(error.localizedDescription, privacy: .public)")
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(10))
        timer.setEventHandler { heartbeat(at: url) }
        timer.resume()
        heartbeatTimer = timer

        // The app lives for the whole process, so this observer is never
        // removed; there is no deinit for it to be removed in. The timer is
        // not cancelled here either: a heartbeat that fires after the removal
        // touches a file that is gone, which is a silent no-op, and the
        // process is about to exit.
        // swiftlint:disable:next discarded_notification_center_observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil,
        ) { _ in
            remove(at: url)
        }
    }

    /// Whether `pid` is a running instance of this bundle other than this one.
    /// The bundle check matters because the marker outlives its process and
    /// the kernel reuses process IDs; the same-process check because a marker
    /// naming this very process can only be a reused ID too.
    private static func isAnotherInstance(_ pid: pid_t) -> Bool {
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
