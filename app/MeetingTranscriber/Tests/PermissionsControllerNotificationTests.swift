@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// Notification authorisation is polled alongside the TCC health check, but is
/// deliberately NOT part of `HealthCheckResult`.
///
/// Three reasons. It only matters when browser watching is on, so folding it
/// into the always-on problem set would badge the menu bar for a permission most
/// users never need, and would change the meaning of the existing
/// `/state.permissionHealth.isHealthy` wire field. `PermissionsController.handle`
/// reacts to a new problem set by posting a NOTIFICATION, which is
/// self-defeating when the problem is that notifications do not arrive. And the
/// types do not line up: `PermissionStatus.broken` means "TCC says yes, the live
/// probe says no", which has no counterpart in `UNAuthorizationStatus`, while
/// `provisional` and `ephemeral` have none in `PermissionStatus`.
@MainActor
final class PermissionsControllerNotificationTests: XCTestCase {
    private func healthyProbe() -> () -> HealthCheckResult {
        { HealthCheckResult(screenRecording: .healthy, microphone: .healthy, accessibility: .healthy) }
    }

    private func makeController(
        authorization: UNAuthorizationStatus,
        notifier: RecordingNotifier = RecordingNotifier(),
    ) -> PermissionsController {
        notifier.authorizationStatus = authorization
        return PermissionsController(notifier: notifier, probe: healthyProbe())
    }

    func test_authorization_isUnknownBeforeTheFirstCheck() {
        let controller = makeController(authorization: .denied)
        XCTAssertNil(controller.notificationAuthorization)
    }

    func test_check_refreshesTheAuthorizationStatus() async {
        let controller = makeController(authorization: .denied)
        await controller.check()
        XCTAssertEqual(controller.notificationAuthorization, .denied)
    }

    /// The user revoking notifications in System Settings mid-session is the
    /// whole reason this is polled rather than cached at launch.
    func test_check_picksUpARevocation() async {
        let notifier = RecordingNotifier()
        let controller = makeController(authorization: .authorized, notifier: notifier)
        await controller.check()
        XCTAssertEqual(controller.notificationAuthorization, .authorized)

        notifier.authorizationStatus = .denied
        await controller.check()
        XCTAssertEqual(controller.notificationAuthorization, .denied)
    }

    /// Denied notifications must never reach the notify path, or the app tries
    /// to report a broken notification channel through that same channel.
    func test_deniedNotifications_doNotPostANotification() async {
        let notifier = RecordingNotifier()
        let controller = makeController(authorization: .denied, notifier: notifier)
        await controller.check()
        XCTAssertTrue(
            notifier.calls.isEmpty,
            "healthy TCC + denied notifications must stay silent, got \(notifier.calls)",
        )
    }
}
