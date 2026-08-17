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
            XCTAssertTrue(result.recordingBlockers(for: .appAndMic(pid: 1)).isEmpty)
            XCTAssertNil(result.recordingRefusalReason(for: .appAndMic(pid: 1)))
        }
    }

    func testMicrophoneProblemsBlockRecording() {
        for (status, problem) in [
            (PermissionStatus.denied, PermissionProblem.microphoneDenied),
            (.broken, .microphoneBroken),
        ] {
            let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: status)
            XCTAssertEqual(result.recordingBlockers(for: .appAndMic(pid: 1)), [problem])
            XCTAssertNotNil(result.recordingRefusalReason(for: .appAndMic(pid: 1)))
        }
    }

    func testScreenRecordingProblemsBlockRecording() {
        for (status, problem) in [
            (PermissionStatus.denied, PermissionProblem.screenRecordingDenied),
            (.broken, .screenRecordingBroken),
        ] {
            let result = PermissionHealthCheck.overallHealth(screenRecording: status, microphone: .healthy)
            XCTAssertEqual(result.recordingBlockers(for: .appAndMic(pid: 1)), [problem])
            XCTAssertNotNil(result.recordingRefusalReason(for: .appAndMic(pid: 1)))
        }
    }

    func testMicrophoneProblemDoesNotBlockAMicLessRecording() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .denied)
        XCTAssertNotNil(result.recordingRefusalReason(for: .appAndMic(pid: 1)))
        // A no-mic recording captures app audio only, so it never asks for the grant.
        XCTAssertNil(result.recordingRefusalReason(for: .appOnly(pid: 1)))
    }

    func testScreenRecordingProblemStillBlocksAMicLessRecording() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .denied, microphone: .healthy)
        XCTAssertNotNil(result.recordingRefusalReason(for: .appOnly(pid: 1)))
    }

    func testRefusalReasonNamesOnlyBlockingProblems() throws {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .denied,
            accessibility: .denied,
        )
        let body = try XCTUnwrap(result.recordingRefusalReason(for: .appAndMic(pid: 1)))
        XCTAssertTrue(body.contains("Microphone"))
        XCTAssertFalse(body.contains("Accessibility"))
        // The aggregate body is untouched and still names both.
        XCTAssertTrue(result.notificationBody.contains("Microphone"))
        XCTAssertTrue(result.notificationBody.contains("Accessibility"))
    }

    func testRefusalReasonNamesEveryBlockingProblem() throws {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .denied, microphone: .denied)
        XCTAssertEqual(result.recordingBlockers(for: .appAndMic(pid: 1)).count, 2)
        // Without this, naming only the first blocker passes every other test, and a
        // user who fixes the one permission the message named is refused a second
        // time over one that was equally blocking and equally known the first time.
        let reason = try XCTUnwrap(result.recordingRefusalReason(for: .appAndMic(pid: 1)))
        XCTAssertTrue(reason.contains("Screen Recording"))
        XCTAssertTrue(reason.contains("Microphone"))
    }

    func testHealthyBlocksNothing() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
        XCTAssertNil(result.recordingRefusalReason(for: .appAndMic(pid: 1)))
    }

    // MARK: - The full matrix

    /// Every (problem, source) cell spelled out, because the exhaustive switch
    /// in `blocksRecording` does not actually force a new permission to be
    /// classified: `HealthCheckResult.problems` is hand-written, so a status
    /// added there with no case reaching this switch compiles clean and
    /// silently blocks nothing. Only these assertions notice.
    func testBlockingMatrix() {
        let app = RecordingSource.appAndMic(pid: 1)
        let appOnly = RecordingSource.appOnly(pid: 1)
        let micOnly = RecordingSource.micOnly

        // Screen Recording gates the process tap, so it blocks exactly the
        // sources that open one.
        for problem in [PermissionProblem.screenRecordingDenied, .screenRecordingBroken] {
            XCTAssertTrue(problem.blocksRecording(for: app))
            XCTAssertTrue(problem.blocksRecording(for: appOnly))
            XCTAssertFalse(problem.blocksRecording(for: micOnly), "no tap is opened, so the tap's proxy grant is irrelevant")
        }

        // The microphone grant blocks exactly the sources that record a mic.
        for problem in [PermissionProblem.microphoneDenied, .microphoneBroken] {
            XCTAssertTrue(problem.blocksRecording(for: app))
            XCTAssertFalse(problem.blocksRecording(for: appOnly))
            XCTAssertTrue(problem.blocksRecording(for: micOnly))
        }

        // Accessibility feeds participant names only, never a capture channel.
        for problem in [PermissionProblem.accessibilityDenied, .accessibilityBroken] {
            for source in [app, appOnly, micOnly] {
                XCTAssertFalse(problem.blocksRecording(for: source))
            }
        }
    }

    func testDeniedScreenRecordingDoesNotBlockAMicrophoneOnlyRecording() {
        // The behaviour issue #633 turns on. Screen Recording is only a
        // preflightable proxy for the app-audio tap; a recording that opens no
        // tap has nothing to preflight, and refusing it would leave the one
        // capture path that needs no tap unusable on exactly the machines that
        // withhold the grant.
        let result = PermissionHealthCheck.overallHealth(screenRecording: .denied, microphone: .healthy)

        XCTAssertNil(result.recordingRefusalReason(for: .micOnly))
        XCTAssertNotNil(result.recordingRefusalReason(for: .appAndMic(pid: 1)), "the app path still refuses")
    }

    func testDeniedMicrophoneBlocksAMicrophoneOnlyRecording() {
        // The other half, and the one that must not be lost while relaxing the
        // first: without the mic grant a mic-only recording captures nothing at
        // all, so it is the one source for which this grant is mandatory.
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .denied)

        XCTAssertEqual(result.recordingBlockers(for: .micOnly), [.microphoneDenied])
        XCTAssertNotNil(result.recordingRefusalReason(for: .micOnly))
    }
}
