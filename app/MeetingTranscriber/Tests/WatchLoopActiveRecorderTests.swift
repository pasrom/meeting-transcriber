@testable import MeetingTranscriber
import XCTest

@MainActor
private final class CapturingRecorder: RecordingProvider {
    var startCalled = false
    var stopCalled = false
    var captureOnStop: @MainActor () -> Void = {}
    let mixPath = URL(fileURLWithPath: "/tmp/test_active_recorder.wav")
    var appLevelDBFS: Double = -120
    var micLevelDBFS: Double = -120

    // Captured start(...) args — appPID + noMic only, since this file's test
    // doesn't exercise micDeviceUID threading (covered in WatchLoopTests).
    // Defaults are deliberately "impossible" so a dropped/inverted argument
    // fails an equality assertion instead of passing.
    var capturedAppPID: pid_t = -1
    var capturedNoMic = false

    func start(appPID: pid_t, noMic: Bool, micDeviceUID _: String?, debugLogging _: Bool) {
        startCalled = true
        capturedAppPID = appPID
        capturedNoMic = noMic
    }

    func stop() -> RecordingResult {
        stopCalled = true
        captureOnStop()
        return RecordingResult(
            mixPath: mixPath,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            recordingStartDate: Date(),
        )
    }
}

/// Regression coverage for the bug where `handleMeeting` (auto-watch path)
/// never assigned `activeRecorder`, leaving `AppState`'s channel-health
/// polling task reading nil on every tick — the red-tint indicator never
/// fired during real recordings. Manual recording was already wired
/// correctly. This test pins the auto-watch path to the same contract.
@MainActor
final class WatchLoopActiveRecorderTests: XCTestCase {
    func testHandleMeetingExposesActiveRecorderForChannelHealthPolling() async throws {
        let recorder = CapturingRecorder()
        let loop = WatchLoop(
            detector: ImmediatelyInactiveDetector(),
            recorderFactory: { recorder },
            pipelineQueue: nil,
            pollInterval: 0.01,
            endGracePeriod: 0.01,
            maxDuration: 10,
            noMic: true,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }

        nonisolated(unsafe) var captured: (any RecordingProvider)?
        recorder.captureOnStop = { [weak loop] in
            captured = loop?.activeRecorder
        }

        let meeting = DetectedMeeting(
            pattern: .teams,
            windowTitle: "Test Meeting | Microsoft Teams",
            ownerName: "Microsoft Teams",
            windowPID: 9999,
        )

        try await loop.handleMeeting(meeting)

        XCTAssertTrue(recorder.startCalled, "recorder.start must be called during handleMeeting")
        XCTAssertEqual(
            recorder.capturedAppPID, meeting.windowPID,
            "auto-watch start must tap the detected meeting's window PID",
        )
        XCTAssertTrue(
            recorder.capturedNoMic,
            "loop's noMic=true must reach the recorder on the auto-watch path",
        )
        XCTAssertTrue(recorder.stopCalled, "recorder.stop must be called during handleMeeting")
        XCTAssertIdentical(
            captured as AnyObject?,
            recorder,
            "activeRecorder must reference the recorder the loop is driving while handleMeeting runs",
        )
        XCTAssertNil(
            loop.activeRecorder,
            "activeRecorder must be cleared after handleMeeting returns (defer)",
        )
    }
}
