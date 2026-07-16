@testable import MeetingTranscriber
import XCTest

@MainActor
final class WatchLoopMeetingStartTimeTests: XCTestCase {
    /// The enqueued job must carry the exact wall-clock `Date` the recorder
    /// captured at recording start, passed through verbatim — no derivation
    /// from `systemUptime`. The previous implementation reconstructed the start
    /// via `Date() - (systemUptime_now - recordingStartUptime)`, which skews for
    /// any meeting spanning a sleep (uptime freezes while asleep). Injecting a
    /// fixed absolute instant the uptime math would never reproduce pins that:
    /// pass-through yields exactly this instant; the old round-trip yields ~now.
    func testEnqueueAnchorsMeetingStartTimeOnRecorderStartDate() async throws {
        let fixedStart = Date(timeIntervalSince1970: 1_600_000_000) // 2020-09-13, far from "now"
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_meeting_start_time.wav")
        recorder.recordingStartDate = fixedStart
        let queue = PipelineQueue()
        let loop = WatchLoop(
            detector: ImmediatelyInactiveDetector(),
            recorderFactory: { recorder },
            pipelineQueue: queue,
            pollInterval: 0.01,
            endGracePeriod: 0.01,
            maxDuration: 10,
            noMic: true,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        let meeting = DetectedMeeting(
            pattern: .teams,
            windowTitle: "Test Meeting | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: 9999,
        )
        try await loop.handleMeeting(meeting)

        let job = try XCTUnwrap(queue.jobs.first, "handleMeeting must enqueue a job")
        let startTime = try XCTUnwrap(
            job.meetingStartTime,
            "enqueue must anchor meetingStartTime on the recorder's recordingStartDate",
        )
        XCTAssertEqual(
            startTime, fixedStart,
            "meetingStartTime must be the recorder's captured start Date verbatim, not derived from uptime",
        )
    }
}
