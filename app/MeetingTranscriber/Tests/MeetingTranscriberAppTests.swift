@testable import MeetingTranscriber
import XCTest

@MainActor
final class MeetingTranscriberAppTests: XCTestCase {
    // MARK: - shouldAutoWatch

    func testAutoWatchWithFlag() {
        let result = MeetingTranscriberApp.shouldAutoWatch(
            commandLineArgs: ["app", "--auto-watch"],
            autoWatchSetting: false,
        )
        XCTAssertTrue(result)
    }

    func testAutoWatchWithSetting() {
        let result = MeetingTranscriberApp.shouldAutoWatch(
            commandLineArgs: [],
            autoWatchSetting: true,
        )
        XCTAssertTrue(result)
    }

    func testAutoWatchBothFalse() {
        let result = MeetingTranscriberApp.shouldAutoWatch(
            commandLineArgs: [],
            autoWatchSetting: false,
        )
        XCTAssertFalse(result)
    }

    // MARK: - lastCompletedProtocolPath

    func testLastProtocolPathReturnsLatestJob() {
        let url = URL(fileURLWithPath: "/tmp/protocol.md")
        var job = PipelineJob(
            meetingTitle: "Test",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.protocolPath = url

        let result = MeetingTranscriberApp.lastCompletedProtocolPath(completedJobs: [job])
        XCTAssertEqual(result, url)
    }

    func testLastProtocolPathEmptyJobsReturnsNil() {
        let result = MeetingTranscriberApp.lastCompletedProtocolPath(completedJobs: [])
        XCTAssertNil(result)
    }

    func testLastProtocolPathNoProtocolReturnsNil() {
        let job = PipelineJob(
            meetingTitle: "Test",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        let result = MeetingTranscriberApp.lastCompletedProtocolPath(completedJobs: [job])
        XCTAssertNil(result)
    }

    // MARK: - reportPreviousExit (issue #703)

    /// The one outcome that reaches the user: a marker whose process is gone.
    /// The notification carries the notice's title and the window.
    func testAnUncleanPreviousExitIsReportedWithItsWindow() throws {
        let notifier = RecordingNotifier()
        let lastAlive = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-09T10:52:00Z"))
        let now = lastAlive.addingTimeInterval(3 * 3600)

        MeetingTranscriberApp.reportPreviousExit(.unclean(lastAlive: lastAlive), to: notifier, now: now)

        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(notifier.calls.first?.title, PreviousExitNotice.title)
        XCTAssertEqual(notifier.calls.first?.body, PreviousExitNotice(lastAlive: lastAlive, now: now).body)
    }

    /// A clean quit is the normal launch and must stay silent, or the notice
    /// becomes noise the user learns to dismiss before the launch it matters.
    func testACleanPreviousExitIsNotReported() {
        let notifier = RecordingNotifier()

        MeetingTranscriberApp.reportPreviousExit(.clean, to: notifier)

        XCTAssertTrue(notifier.calls.isEmpty)
    }

    /// A second instance is not a crash, so opening the app twice must not
    /// claim it was down.
    func testAStillRunningInstanceIsNotReported() {
        let notifier = RecordingNotifier()

        MeetingTranscriberApp.reportPreviousExit(.stillRunning(pid: 4242), to: notifier)

        XCTAssertTrue(notifier.calls.isEmpty)
    }
}
