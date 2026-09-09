@testable import MeetingTranscriber
import XCTest

/// The process-lifetime marker behind issue #703. The recording marker
/// (`RecordingFileSuffix.inProgress`) only exists while a recording is in
/// flight, so an app that crashes while idle leaves nothing behind and the
/// next launch cannot tell that the previous one ended without a quit. This
/// marker exists for the whole run instead.
@MainActor
final class LivenessMarkerTests: XCTestCase {
    /// The clean case and the first launch look the same: nothing on disk.
    func testNoMarkerMeansThePreviousRunQuitCleanly() throws {
        let url = try makeTempDirectory(prefix: "liveness_none").appendingPathComponent("marker")

        let exit = LivenessMarker.inspect(at: url) { _ in
            XCTFail("there is no process to ask about")
            return true
        }

        XCTAssertEqual(exit, .clean)
    }

    /// THE case the feature exists for: a marker whose process is gone. The
    /// reported time is the last heartbeat, which bounds the window in which
    /// nothing was watching for meetings.
    func testAMarkerWhoseProcessIsGoneMeansAnUncleanExitAtItsLastHeartbeat() throws {
        let url = try makeTempDirectory(prefix: "liveness_dead").appendingPathComponent("marker")
        try LivenessMarker.write(pid: 4242, at: url)
        let lastHeartbeat = Date(timeIntervalSinceNow: -3600)
        try backdate(url, to: lastHeartbeat)

        var asked: [pid_t] = []
        let exit = LivenessMarker.inspect(at: url) { pid in
            asked.append(pid)
            return false
        }

        guard case let .unclean(lastAlive) = exit else {
            XCTFail("expected an unclean exit, got \(exit)")
            return
        }
        XCTAssertEqual(lastAlive.timeIntervalSince1970, lastHeartbeat.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(asked, [4242], "the verdict must rest on the recorded process, not on this one")
    }

    /// The control case for the one above. A marker whose process is alive is
    /// a second instance of this bundle, not a crash; reporting it as one would
    /// fire a false alarm every time the app is opened twice.
    func testAMarkerWhoseProcessIsAliveMeansAnotherInstanceIsRunning() throws {
        let url = try makeTempDirectory(prefix: "liveness_alive").appendingPathComponent("marker")
        try LivenessMarker.write(pid: 4242, at: url)

        let exit = LivenessMarker.inspect(at: url) { _ in true }

        XCTAssertEqual(exit, .stillRunning(pid: 4242))
    }

    /// A marker is written once at launch, so without the heartbeat its age
    /// would be the run's length and the reported window would start at
    /// launch, which for a crash after a morning of successful recordings is
    /// hours too early.
    func testHeartbeatMovesLastAliveForward() throws {
        let url = try makeTempDirectory(prefix: "liveness_beat").appendingPathComponent("marker")
        try LivenessMarker.write(pid: 4242, at: url)
        try backdate(url, to: Date(timeIntervalSinceNow: -3600))

        LivenessMarker.heartbeat(at: url)

        let exit = LivenessMarker.inspect(at: url) { _ in false }
        guard case let .unclean(lastAlive) = exit else {
            XCTFail("the marker must still be there after a heartbeat")
            return
        }
        XCTAssertEqual(lastAlive.timeIntervalSinceNow, 0, accuracy: 5)
    }

    /// A clean quit removes the marker, and that removal is the entire
    /// difference between a quit and a crash as seen from the next launch.
    func testRemoveLeavesNoMarker() throws {
        let url = try makeTempDirectory(prefix: "liveness_remove").appendingPathComponent("marker")
        try LivenessMarker.write(pid: 4242, at: url)

        LivenessMarker.remove(at: url)

        let exit = LivenessMarker.inspect(at: url) { _ in false }
        XCTAssertEqual(exit, .clean)
    }

    /// Removing what is not there is what a quit after a failed write does,
    /// and must not be an error.
    func testRemoveWithoutAMarkerIsANoOp() throws {
        let url = try makeTempDirectory(prefix: "liveness_remove_none").appendingPathComponent("marker")

        LivenessMarker.remove(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// The first launch on a machine has no data directory yet.
    func testWriteCreatesTheDirectoryWhenMissing() throws {
        let url = try makeTempDirectory(prefix: "liveness_mkdir")
            .appendingPathComponent("not").appendingPathComponent("yet").appendingPathComponent("marker")

        try LivenessMarker.write(pid: 4242, at: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// The default records the calling process, so the next launch can ask
    /// whether that process is still around.
    func testWriteRecordsThisProcess() throws {
        let url = try makeTempDirectory(prefix: "liveness_self").appendingPathComponent("marker")

        try LivenessMarker.write(at: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\(getpid())")
    }

    /// A marker that cannot be parsed still means a run left it behind. Reading
    /// it as clean would hide exactly the exits this exists to surface, and
    /// there is no process to ask about, so the liveness check is never made.
    func testAnUnreadableMarkerStillCountsAsAnUncleanExit() throws {
        let url = try makeTempDirectory(prefix: "liveness_garbage").appendingPathComponent("marker")
        try Data("not a pid".utf8).write(to: url)

        let exit = LivenessMarker.inspect(at: url) { _ in
            XCTFail("there is no process to ask about")
            return true
        }

        guard case .unclean = exit else {
            XCTFail("expected an unclean exit, got \(exit)")
            return
        }
    }

    // MARK: - arm

    /// `arm` is inspect and take-over in one call, because the order is
    /// load-bearing (an inspect after the write would find this run's own
    /// marker) and the verdict must come from the marker as it was BEFORE this
    /// run touched it. The launcher reads the verdict from this call and
    /// nothing else.
    func testArmReportsThePreviousRunAndTakesOverTheMarker() throws {
        let url = try makeTempDirectory(prefix: "liveness_arm_takeover").appendingPathComponent("marker")
        try LivenessMarker.write(pid: 4242, at: url)
        let lastHeartbeat = Date(timeIntervalSinceNow: -3600)
        try backdate(url, to: lastHeartbeat)

        let exit = LivenessMarker.arm(at: url, heartbeat: 3600) { _ in false }

        guard case let .unclean(lastAlive) = exit else {
            XCTFail("expected the previous run's unclean exit, got \(exit)")
            return
        }
        XCTAssertEqual(lastAlive.timeIntervalSince1970, lastHeartbeat.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\(getpid())", "this run owns the marker now")
    }

    /// The first launch on a machine, and every launch after a clean quit.
    func testArmOnACleanSlateReportsCleanAndWritesTheMarker() throws {
        let url = try makeTempDirectory(prefix: "liveness_arm_clean").appendingPathComponent("marker")

        let exit = LivenessMarker.arm(at: url, heartbeat: 3600) { _ in false }

        XCTAssertEqual(exit, .clean)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\(getpid())")
    }

    /// The production liveness check on a process that is not this app: pid 1
    /// is launchd, alive for as long as the machine is and never an instance
    /// of this bundle, so its marker is a dead run's marker.
    func testAForeignProcessIsNotARunningInstance() throws {
        let url = try makeTempDirectory(prefix: "liveness_foreign").appendingPathComponent("marker")
        try LivenessMarker.write(pid: 1, at: url)

        let exit = LivenessMarker.inspect(at: url)

        guard case .unclean = exit else {
            XCTFail("expected an unclean exit, got \(exit)")
            return
        }
    }

    /// The clean-quit half, driven the way AppKit drives it: the notification
    /// on the default centre. The observer runs synchronously, so the marker
    /// is gone by the time the post returns.
    func testACleanTerminationReleasesTheMarker() throws {
        let url = try makeTempDirectory(prefix: "liveness_terminate").appendingPathComponent("marker")
        _ = LivenessMarker.arm(at: url, heartbeat: 3600) { _ in false }

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Two instances share one marker and the later one owns it: it wrote its
    /// own PID over the first one's. The first instance quitting cleanly must
    /// then leave the marker alone, or the second runs unprotected from that
    /// moment on and its crash goes unreported.
    func testATerminationLeavesAMarkerAnotherInstanceTookOver() throws {
        let url = try makeTempDirectory(prefix: "liveness_terminate_other").appendingPathComponent("marker")
        _ = LivenessMarker.arm(at: url, heartbeat: 3600) { _ in false }
        try LivenessMarker.write(pid: 4242, at: url) // the second instance took over

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8), "4242",
            "the marker belongs to the other instance now",
        )
    }

    /// A DispatchTime timer does not run while the machine sleeps, so after
    /// a night with the lid closed the last heartbeat is from the evening
    /// before. A crash shortly after waking would then claim a window of
    /// fifteen hours in which no meeting could have been missed. Waking
    /// touches the marker, so the claimed window starts at the wake and not
    /// at the sleep. Driven the way AppKit drives it: the workspace
    /// notification, not the timer.
    func testWakingFromSleepTouchesTheMarker() throws {
        let url = try makeTempDirectory(prefix: "liveness_wake").appendingPathComponent("marker")
        _ = LivenessMarker.arm(at: url, heartbeat: 3600) { _ in false }
        try backdate(url, to: Date(timeIntervalSinceNow: -15 * 3600))

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        let exit = LivenessMarker.inspect(at: url) { _ in false }
        guard case let .unclean(lastAlive) = exit else {
            XCTFail("the marker must still be there after a wake, got \(exit)")
            return
        }
        XCTAssertEqual(lastAlive.timeIntervalSinceNow, 0, accuracy: 5, "the window must start at the wake")
    }

    /// A write that fails must not leave the previous run's dead marker in
    /// place, or every later launch reposts the same notice with a window
    /// that never ends. A marker that is a directory is the one shape that
    /// reads as a dead marker AND defeats the atomic write of the new one,
    /// so it stands in for a full disk here.
    func testAFailedWriteRemovesTheStaleMarkerItCouldNotReplace() throws {
        let url = try makeTempDirectory(prefix: "liveness_write_fails").appendingPathComponent("marker")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try backdate(url, to: Date(timeIntervalSinceNow: -3600))

        let exit = LivenessMarker.arm(at: url, heartbeat: 3600) { _ in false }

        guard case .unclean = exit else {
            XCTFail("this launch still reports the dead marker once, got \(exit)")
            return
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "the dead marker must not be there for the next launch to report again",
        )
    }

    /// The heartbeat itself. Its interval is what bounds how stale the
    /// reported time can be, so the timer has to touch the marker it was
    /// armed with. A short interval keeps the test about the mechanism
    /// without waiting a minute; the timer repeats, so a first tick landing
    /// before the backdate is overtaken by the next.
    func testTheHeartbeatTouchesTheMarker() async throws {
        let url = try makeTempDirectory(prefix: "liveness_heartbeat").appendingPathComponent("marker")
        _ = LivenessMarker.arm(at: url, heartbeat: 0.05) { _ in false }
        let launch = Date(timeIntervalSinceNow: -3600)
        try backdate(url, to: launch)

        await waitFor(self.modificationDate(of: url) > launch.addingTimeInterval(1800), timeout: .seconds(5))

        XCTAssertGreaterThan(
            modificationDate(of: url), launch.addingTimeInterval(1800),
            "the heartbeat must move the marker's age along with the process",
        )
    }

    /// The other half of the production liveness check: a process that IS a
    /// running application, just not one of this bundle, whose marker is
    /// therefore a dead run's marker. Any other application on the session
    /// will do; a session with none skips rather than inventing one.
    func testAnotherApplicationsProcessIsNotARunningInstanceOfThisBundle() throws {
        guard let other = NSWorkspace.shared.runningApplications.first(where: { app in
            app.processIdentifier != getpid() && app.bundleIdentifier != Bundle.main.bundleIdentifier
        }) else {
            throw XCTSkip("no other running application on this session")
        }
        let url = try makeTempDirectory(prefix: "liveness_other_app").appendingPathComponent("marker")
        try LivenessMarker.write(pid: other.processIdentifier, at: url)

        let exit = LivenessMarker.inspect(at: url)

        guard case .unclean = exit else {
            XCTFail("expected an unclean exit for another application's process, got \(exit)")
            return
        }
    }

    /// THE ordering guard. Reading the marker after this run has written it
    /// must not turn into a notice: the recorded process is this one, and
    /// this one is running. A second inspect, or an arm at a second call
    /// site, is then harmless instead of a false notice on every launch.
    func testInspectingAfterArmingIsNotAnUncleanExit() throws {
        let url = try makeTempDirectory(prefix: "liveness_arm_reinspect").appendingPathComponent("marker")
        _ = LivenessMarker.arm(at: url, heartbeat: 3600)

        let exit = LivenessMarker.inspect(at: url)

        XCTAssertEqual(exit, .stillRunning(pid: getpid()))
    }

    /// Set the marker's modification time, the way a heartbeat does.
    private func backdate(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func modificationDate(of url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }
}
