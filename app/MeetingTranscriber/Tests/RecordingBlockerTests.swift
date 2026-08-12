@testable import MeetingTranscriber
import XCTest

/// Which permission problems have to stop a recording from starting, as opposed
/// to only degrading a side feature. Deliberately a different question from the
/// aggregate `isHealthy` in `PermissionHealthCheckTests`: these two must be able
/// to disagree, and several of the assertions below exist to pin exactly that.
final class RecordingBlockerTests: XCTestCase {
    func testAccessibilityProblemsDoNotBlockRecording() {
        for status in [PermissionStatus.denied, .broken] {
            let result = PermissionHealthCheck.overallHealth(
                screenRecording: .healthy,
                microphone: .healthy,
                accessibility: status,
            )
            // The menu bar badge and the permission notification still report a
            // problem, the recording gate does not. Anything that collapses the
            // two notions back together breaks here.
            XCTAssertFalse(result.isHealthy, "accessibility \(status) is still a reported problem")
            XCTAssertTrue(result.recordingBlockers(noMic: false).isEmpty)
            XCTAssertNil(result.recordingRefusalReason(noMic: false))
        }
    }

    func testMicrophoneProblemsBlockRecording() {
        for (status, problem) in [
            (PermissionStatus.denied, PermissionProblem.microphoneDenied),
            (.broken, .microphoneBroken),
        ] {
            let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: status)
            XCTAssertEqual(result.recordingBlockers(noMic: false), [problem])
            XCTAssertNotNil(result.recordingRefusalReason(noMic: false))
        }
    }

    func testScreenRecordingProblemsBlockRecording() {
        for (status, problem) in [
            (PermissionStatus.denied, PermissionProblem.screenRecordingDenied),
            (.broken, .screenRecordingBroken),
        ] {
            let result = PermissionHealthCheck.overallHealth(screenRecording: status, microphone: .healthy)
            XCTAssertEqual(result.recordingBlockers(noMic: false), [problem])
            XCTAssertNotNil(result.recordingRefusalReason(noMic: false))
        }
    }

    func testMicrophoneProblemDoesNotBlockAMicLessRecording() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .denied)
        XCTAssertNotNil(result.recordingRefusalReason(noMic: false))
        // A no-mic recording captures app audio only, so it never asks for the grant.
        XCTAssertNil(result.recordingRefusalReason(noMic: true))
    }

    func testScreenRecordingProblemStillBlocksAMicLessRecording() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .denied, microphone: .healthy)
        XCTAssertNotNil(result.recordingRefusalReason(noMic: true))
    }

    func testRefusalReasonNamesOnlyBlockingProblems() throws {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .denied,
            accessibility: .denied,
        )
        let body = try XCTUnwrap(result.recordingRefusalReason(noMic: false))
        XCTAssertTrue(body.contains("Microphone"))
        XCTAssertFalse(body.contains("Accessibility"))
        // The aggregate body is untouched and still names both.
        XCTAssertTrue(result.notificationBody.contains("Microphone"))
        XCTAssertTrue(result.notificationBody.contains("Accessibility"))
    }

    func testRefusalReasonNamesEveryBlockingProblem() throws {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .denied, microphone: .denied)
        XCTAssertEqual(result.recordingBlockers(noMic: false).count, 2)
        // Without this, naming only the first blocker passes every other test, and a
        // user who fixes the one permission the message named is refused a second
        // time over one that was equally blocking and equally known the first time.
        let reason = try XCTUnwrap(result.recordingRefusalReason(noMic: false))
        XCTAssertTrue(reason.contains("Screen Recording"))
        XCTAssertTrue(reason.contains("Microphone"))
    }

    func testHealthyBlocksNothing() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
        XCTAssertNil(result.recordingRefusalReason(noMic: false))
    }
}
