@testable import MeetingTranscriber
import XCTest

/// The auto-watch half of the record-only destination seam. `WatchingController`
/// hands the loop a destination closure in two places, one per loop it builds,
/// and a test of the manual one (`WatchingControllerManualRecordingTests`) says
/// nothing about this one, which is the primary product path: a meeting the
/// detector found, recorded in record-only mode, written to a folder that is
/// no longer there.
///
/// Its own file: `WatchingControllerTests` sits at the 600-line cap, and the
/// manual suite is about manual recording.
@MainActor
final class WatchingControllerRecordOnlyTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerRecordOnlyTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// The recording must be kept, and the user must be told it went elsewhere.
    /// Driven through the controller's own `startWatching`, so the closure under
    /// test is the production one and not a stand-in from `makeTestWatchLoop`.
    ///
    /// The meeting is ended by stopping the watch: `WatchLoop.handleMeeting`
    /// treats a cancel mid-recording like a natural end and finalizes, which is
    /// the same `enqueueRecording` a grace-period end reaches, without waiting
    /// out the one-second floor on `endGrace`. The sidecar's `trigger` pins that
    /// it was this path and not the manual one that wrote the output.
    func testADetectedMeetingWhoseFolderIsGoneIsKeptInTheDefaultFolderAndTheUserIsTold() async throws {
        let notifier = RecordingNotifier()
        let recorder = makeMockRecorder()
        // A real file, so the record-only move succeeds and the test can say
        // where the recording ended up, not only that a notification fired.
        let mix = tmpDir.appendingPathComponent("20260908_100000_mix.wav")
        try Data().write(to: mix)
        recorder.mixPath = mix
        let controller = makeWatchingController(
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy,
            makeDetector: { FixedMeetingDetector() },
            makeRecorder: { recorder },
        )
        controller.settings.recordOnly = true
        let chosen = try makeTempDirectory(prefix: "ChosenOutputDir")
        controller.settings.setCustomOutputDir(chosen)
        try FileManager.default.removeItem(at: chosen)

        let started = await controller.startWatching()
        XCTAssertEqual(started, .changed, "precondition")
        await waitFor(controller.watchLoop?.state == .recording, timeout: .seconds(2))
        XCTAssertEqual(controller.watchLoop?.state, .recording, "precondition: the meeting must be recording by now")

        let stopped = await controller.stopWatching()
        XCTAssertEqual(stopped, .changed, "precondition")
        // The finalize runs on the cancelled task after `stop()` returns; the
        // sidecar is the last thing it writes, so its presence means the whole
        // record-only write, notification included, has happened.
        let recordings = tmpDir.appendingPathComponent("output/recordings")
        let sidecar = recordings.appendingPathComponent("20260908_100000\(RecordingSidecar.filenameSuffix)")
        await waitFor(FileManager.default.fileExists(atPath: sidecar.path), timeout: .seconds(2))

        let titles = notifier.calls.map(\.title)
        XCTAssertTrue(titles.contains(OutputDirectoryResolver.unavailableTitle), "user was told: \(titles)")
        XCTAssertFalse(titles.contains("Record-only output failed"), "the recording was kept: \(titles)")
        // The factory points the default folder at `<logDir>/output`, standing in
        // for `~/Downloads/MeetingTranscriber`.
        let written = try FileManager.default.contentsOfDirectory(atPath: recordings.path)
        XCTAssertTrue(written.contains("20260908_100000_mix.wav"), "\(written)")
        let meta = RecordingSidecar.read(fromDirectory: recordings, basename: "20260908_100000")
        XCTAssertEqual(meta?.trigger, .auto, "the auto-watch loop wrote this, not the manual one")
    }
}
