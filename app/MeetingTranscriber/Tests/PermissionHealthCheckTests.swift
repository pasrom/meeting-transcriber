import AVFoundation
@testable import MeetingTranscriber
import XCTest

final class PermissionHealthCheckTests: XCTestCase {
    // MARK: - Screen Recording (new split API)

    func testScreenRecordingHealthy() {
        let result = PermissionHealthCheck.checkScreenRecording(
            systemAllowed: true,
            hasForeignWithTitle: true,
        )
        XCTAssertEqual(result, .healthy)
    }

    func testScreenRecordingDeniedWhenSystemSaysNo() {
        let result = PermissionHealthCheck.checkScreenRecording(
            systemAllowed: false,
            hasForeignWithTitle: false,
        )
        XCTAssertEqual(result, .denied)
    }

    func testScreenRecordingDeniedEvenWithWindows() {
        // System says no — we ignore the probe outcome.
        let result = PermissionHealthCheck.checkScreenRecording(
            systemAllowed: false,
            hasForeignWithTitle: true,
        )
        XCTAssertEqual(result, .denied)
    }

    func testScreenRecordingBrokenSystemAllowsButNoTitles() {
        // TCC says yes but window probe can't see any foreign titles.
        let result = PermissionHealthCheck.checkScreenRecording(
            systemAllowed: true,
            hasForeignWithTitle: false,
        )
        XCTAssertEqual(result, .broken)
    }

    // MARK: - Screen Recording (window list parser)

    func testHasForeignWindowWithTitleTrue() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: [
                [kCGWindowOwnerPID as String: Int32(999), kCGWindowName as String: "Finder"],
            ],
            ownPID: 123,
        )
        XCTAssertTrue(result)
    }

    func testHasForeignWindowWithTitleNilList() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: nil,
            ownPID: 123,
        )
        XCTAssertFalse(result)
    }

    func testHasForeignWindowWithTitleIgnoresOwnPID() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: [
                [kCGWindowOwnerPID as String: Int32(123), kCGWindowName as String: "My App"],
            ],
            ownPID: 123,
        )
        XCTAssertFalse(result)
    }

    func testHasForeignWindowWithTitleEmptyTitle() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: [
                [kCGWindowOwnerPID as String: Int32(999), kCGWindowName as String: ""],
            ],
            ownPID: 123,
        )
        XCTAssertFalse(result)
    }

    func testHasForeignWindowWithTitleEmptyList() {
        let result = PermissionHealthCheck.hasForeignWindowWithTitle(
            windowList: [],
            ownPID: 123,
        )
        XCTAssertFalse(result)
    }

    // MARK: - Microphone

    func testMicHealthy() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .authorized, probeSucceeds: true)
        XCTAssertEqual(result, .healthy)
    }

    func testMicDenied() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .denied, probeSucceeds: false)
        XCTAssertEqual(result, .denied)
    }

    func testMicRestricted() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .restricted, probeSucceeds: false)
        XCTAssertEqual(result, .denied)
    }

    func testMicBroken() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .authorized, probeSucceeds: false)
        XCTAssertEqual(result, .broken)
    }

    func testMicNotDetermined() {
        let result = PermissionHealthCheck.checkMicrophone(authStatus: .notDetermined, probeSucceeds: false)
        XCTAssertEqual(result, .notDetermined)
    }

    // MARK: - Accessibility

    func testAccessibilityHealthy() {
        let result = PermissionHealthCheck.checkAccessibility(trusted: true, probeSucceeds: true)
        XCTAssertEqual(result, .healthy)
    }

    func testAccessibilityDenied() {
        let result = PermissionHealthCheck.checkAccessibility(trusted: false, probeSucceeds: false)
        XCTAssertEqual(result, .denied)
    }

    func testAccessibilityDeniedEvenIfProbeSucceeds() {
        // Defensive: if the system says no, we never report healthy.
        let result = PermissionHealthCheck.checkAccessibility(trusted: false, probeSucceeds: true)
        XCTAssertEqual(result, .denied)
    }

    func testAccessibilityBroken() {
        let result = PermissionHealthCheck.checkAccessibility(trusted: true, probeSucceeds: false)
        XCTAssertEqual(result, .broken)
    }

    // MARK: - Overall Health

    func testOverallHealthy() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .healthy,
        )
        XCTAssertTrue(result.isHealthy)
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testOverallScreenBroken() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .broken, microphone: .healthy)
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.problems, [.screenRecordingBroken])
    }

    func testOverallMicBroken() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .broken)
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.problems, [.microphoneBroken])
    }

    func testOverallAccessibilityBroken() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .broken,
        )
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.problems, [.accessibilityBroken])
    }

    func testOverallAccessibilityDenied() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .denied,
        )
        XCTAssertEqual(result.problems, [.accessibilityDenied])
    }

    func testOverallAllThreeBroken() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .broken,
            microphone: .broken,
            accessibility: .broken,
        )
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.problems.count, 3)
        XCTAssertTrue(result.problems.contains(.screenRecordingBroken))
        XCTAssertTrue(result.problems.contains(.microphoneBroken))
        XCTAssertTrue(result.problems.contains(.accessibilityBroken))
    }

    func testOverallMicNotDeterminedIsHealthy() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .notDetermined)
        XCTAssertTrue(result.isHealthy)
    }

    func testOverallAccessibilityNotDeterminedIsHealthy() {
        let result = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .notDetermined,
        )
        XCTAssertTrue(result.isHealthy)
    }

    func testOverallScreenDenied() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .denied, microphone: .healthy)
        XCTAssertEqual(result.problems, [.screenRecordingDenied])
    }

    func testOverallMicDenied() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .denied)
        XCTAssertEqual(result.problems, [.microphoneDenied])
    }

    // MARK: - Notification Message

    func testBrokenScreenRecordingMessageDistinguishesFromDenied() {
        let broken = PermissionHealthCheck.overallHealth(screenRecording: .broken, microphone: .healthy)
        let denied = PermissionHealthCheck.overallHealth(screenRecording: .denied, microphone: .healthy)
        XCTAssertTrue(broken.notificationBody.contains("Screen Recording"))
        XCTAssertTrue(broken.notificationBody.contains("toggle"))
        XCTAssertTrue(denied.notificationBody.contains("denied"))
        XCTAssertNotEqual(broken.notificationBody, denied.notificationBody)
    }

    func testBrokenMicMessageDistinguishesFromDenied() {
        let broken = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .broken)
        let denied = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .denied)
        XCTAssertTrue(broken.notificationBody.contains("Microphone"))
        XCTAssertTrue(broken.notificationBody.contains("toggle"))
        XCTAssertTrue(denied.notificationBody.contains("denied"))
        XCTAssertNotEqual(broken.notificationBody, denied.notificationBody)
    }

    func testBrokenAccessibilityMessageDistinguishesFromDenied() {
        let broken = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .broken,
        )
        let denied = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .denied,
        )
        XCTAssertTrue(broken.notificationBody.contains("Accessibility"))
        XCTAssertTrue(broken.notificationBody.contains("toggle"))
        XCTAssertTrue(denied.notificationBody.contains("denied"))
        XCTAssertNotEqual(broken.notificationBody, denied.notificationBody)
    }

    func testHealthyNoMessage() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
        XCTAssertTrue(result.notificationBody.isEmpty)
    }

    // MARK: - HealthCheckResult Equatable

    func testHealthCheckResultEquality() {
        let a = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
        let b = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
        XCTAssertEqual(a, b)
    }

    func testHealthCheckResultEqualityDifferentAccessibility() {
        let a = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .healthy,
        )
        let b = PermissionHealthCheck.overallHealth(
            screenRecording: .healthy,
            microphone: .healthy,
            accessibility: .broken,
        )
        XCTAssertNotEqual(a, b)
    }
}
