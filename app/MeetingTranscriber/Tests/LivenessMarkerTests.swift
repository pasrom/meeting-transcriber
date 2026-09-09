@testable import MeetingTranscriber
import XCTest

/// The process-lifetime marker behind issue #703. The recording marker
/// (`RecordingFileSuffix.inProgress`) only exists while a recording is in
/// flight, so an app that crashes while idle leaves nothing behind and the
/// next launch cannot tell that the previous one ended without a quit. This
/// marker exists for the whole run instead.
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

    /// Set the marker's modification time, the way a heartbeat does.
    private func backdate(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
