@testable import MeetingTranscriber
import XCTest

/// Exercises the watch task through a completed auto-detected meeting.
@MainActor
final class WatchLoopMeetingLifecycleTests: XCTestCase {
    func testReturningToWatchingClearsTheFinishedMeeting() async throws {
        let logDir = try makeTempDirectory(prefix: "watch-loop-meeting-lifecycle")
        let queue = PipelineQueue(logDir: logDir)
        let recorder = makeMockRecorder()
        let clock = TestClock()
        let meeting = DetectedMeeting(
            pattern: .zoom,
            windowTitle: "Project Review - Zoom",
            ownerName: "zoom.us",
            windowPID: 4242,
        )
        let loop = WatchLoop(
            detector: FinishedMeetingDetector(meeting: meeting),
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            noMic: { true },
            nowProvider: { clock.now },
            sleepProvider: { await clock.sleep(for: $0) },
        )

        let returnedToWatching = expectation(description: "finished meeting returned to watching")
        var recordingMeeting: DetectedMeeting?
        var watchingSnapshot: WatchLoopState?
        loop.onStateChange = { [weak loop] old, new in
            if new == .recording {
                recordingMeeting = loop?.currentMeeting
            }
            if old == .recording, new == .watching {
                watchingSnapshot = loop?.snapshot
                returnedToWatching.fulfill()
            }
        }

        loop.start()
        defer { loop.stop() }
        await fulfillment(of: [returnedToWatching], timeout: 2)

        XCTAssertEqual(recordingMeeting, meeting)
        let snapshot = try XCTUnwrap(watchingSnapshot)
        XCTAssertEqual(snapshot.phase, .watching)
        XCTAssertNil(snapshot.currentMeeting, "A finished meeting must disappear as soon as watching resumes")
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs.first?.meetingTitle, "Project Review")
        XCTAssertEqual(queue.jobs.first?.appName, "Zoom")
    }
}

/// Detects one meeting, then reports it inactive so the grace period can finish.
private final class FinishedMeetingDetector: MeetingDetecting {
    private var meeting: DetectedMeeting?

    init(meeting: DetectedMeeting) {
        self.meeting = meeting
    }

    func checkOnce() -> DetectedMeeting? {
        meeting
    }

    func isMeetingActive(_: DetectedMeeting) -> Bool {
        false
    }

    func reset(appName _: String?) {
        meeting = nil
    }
}
