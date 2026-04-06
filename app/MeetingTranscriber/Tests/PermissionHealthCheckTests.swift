import AVFoundation
@testable import MeetingTranscriber
import XCTest

final class PermissionHealthCheckTests: XCTestCase {
    // MARK: - Screen Recording

    func testScreenRecordingHealthy() {
        let result = PermissionHealthCheck.checkScreenRecording(windowList: [
            [kCGWindowOwnerPID as String: Int32(999), kCGWindowName as String: "Finder"],
        ], ownPID: 123)
        XCTAssertEqual(result, .healthy)
    }

    func testScreenRecordingDenied() {
        let result = PermissionHealthCheck.checkScreenRecording(windowList: nil, ownPID: 123)
        XCTAssertEqual(result, .denied)
    }

    func testScreenRecordingBrokenNoTitles() {
        let result = PermissionHealthCheck.checkScreenRecording(windowList: [
            [kCGWindowOwnerPID as String: Int32(999)],
            [kCGWindowOwnerPID as String: Int32(888)],
        ], ownPID: 123)
        XCTAssertEqual(result, .broken)
    }

    func testScreenRecordingIgnoresOwnWindows() {
        let result = PermissionHealthCheck.checkScreenRecording(windowList: [
            [kCGWindowOwnerPID as String: Int32(123), kCGWindowName as String: "My App"],
        ], ownPID: 123)
        XCTAssertEqual(result, .broken)
    }

    func testScreenRecordingBrokenEmptyTitle() {
        let result = PermissionHealthCheck.checkScreenRecording(windowList: [
            [kCGWindowOwnerPID as String: Int32(999), kCGWindowName as String: ""],
        ], ownPID: 123)
        XCTAssertEqual(result, .broken)
    }

    func testScreenRecordingEmptyWindowList() {
        let result = PermissionHealthCheck.checkScreenRecording(windowList: [], ownPID: 123)
        XCTAssertEqual(result, .broken)
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

    // MARK: - Overall Health

    func testOverallHealthy() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .healthy)
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

    func testOverallBothBroken() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .broken, microphone: .broken)
        XCTAssertFalse(result.isHealthy)
        XCTAssertEqual(result.problems.count, 2)
    }

    func testOverallMicNotDeterminedIsHealthy() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .notDetermined)
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

    func testBrokenScreenRecordingMessage() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .broken, microphone: .healthy)
        XCTAssertTrue(result.notificationBody.contains("Screen Recording"))
        XCTAssertTrue(result.notificationBody.contains("reset"))
    }

    func testBrokenMicMessage() {
        let result = PermissionHealthCheck.overallHealth(screenRecording: .healthy, microphone: .broken)
        XCTAssertTrue(result.notificationBody.contains("Microphone"))
        XCTAssertTrue(result.notificationBody.contains("reset"))
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
}
