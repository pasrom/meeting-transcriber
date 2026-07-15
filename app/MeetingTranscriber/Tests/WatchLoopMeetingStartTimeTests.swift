@testable import MeetingTranscriber
import XCTest

@MainActor
final class WatchLoopMeetingStartTimeTests: XCTestCase {
    /// The enqueued job must carry the meeting-start wall-clock time derived
    /// from the recorder's `recordingStart` uptime, not the enqueue time.
    /// Before the fix the job had no start-time field at all and filenames were
    /// stamped with `Date()` at save (i.e. processing time).
    func testEnqueueAnchorsMeetingStartTimeOnRecordingStart() async throws {
        // Recording started ~5 minutes ago (in systemUptime terms).
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_meeting_start_time.wav")
        recorder.recordingStartUptime = ProcessInfo.processInfo.systemUptime - 300
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
            "enqueue must anchor meetingStartTime on the recorder's recordingStart",
        )
        let secondsAgo = Date().timeIntervalSince(startTime)
        XCTAssertEqual(
            secondsAgo, 300, accuracy: 10,
            "meetingStartTime should reflect the recording-start uptime (~5 min ago), not the enqueue time",
        )
    }
}
