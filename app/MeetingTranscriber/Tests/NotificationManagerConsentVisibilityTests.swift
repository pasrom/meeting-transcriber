@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// The consent prompt used to be the one notification the app posted that left
/// no trace anywhere an automated driver could read: `notify(...)` records to
/// the ring buffer behind `/state.notifications`, but the consent prompt called
/// `scheduler.add` directly.
///
/// That is what let the browser e2e lane stay green while the feature was dead
/// for users. The lane answers consent over RPC, which resolves the same parked
/// continuation whether or not any notification was ever posted, and with no
/// ring-buffer entry there was nothing else to assert against.
@MainActor
final class NotificationManagerConsentVisibilityTests: XCTestCase {
    #if !APPSTORE
        func test_consentPrompt_isRecordedAsDeliveredWhenItCanBePosted() async {
            let scheduler = FakeNotificationScheduler()
            let canDeliver: @Sendable () -> Bool = { true }
            let manager = NotificationManager(scheduler: scheduler, canDeliver: canDeliver)
            manager.setUp()

            // Resolve it immediately so the test doesn't wait out the 60 s timeout.
            Task { @MainActor in
                while !manager.resolveBrowserConsent(granted: false) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            _ = await manager.askToRecord(title: "Browser Meeting", body: "Record this?")

            let entries = manager.recentNotifications
            let consent = entries.first { $0.title == "Browser Meeting" }
            XCTAssertNotNil(consent, "consent prompt must appear in the ring buffer")
            XCTAssertEqual(consent?.delivered, true)
            XCTAssertEqual(scheduler.added.count, 1, "and must actually have been posted")
        }

        /// The case that matters: no bundle, so nothing is posted and no prompt
        /// can be seen. The ring buffer must still record the app's DECISION to
        /// prompt, flagged undelivered, so a driver can tell "never tried" from
        /// "tried and could not".
        func test_consentPrompt_isRecordedAsUndeliveredWhenItCannotBePosted() async {
            let scheduler = FakeNotificationScheduler()
            let canDeliver: @Sendable () -> Bool = { false }
            let manager = NotificationManager(scheduler: scheduler, canDeliver: canDeliver)
            manager.setUp()

            let granted = await manager.askToRecord(title: "Browser Meeting", body: "Record this?")

            XCTAssertFalse(granted, "must never record without a visible prompt")
            XCTAssertTrue(scheduler.added.isEmpty)
            let consent = manager.recentNotifications.first { $0.title == "Browser Meeting" }
            XCTAssertNotNil(consent, "an unpostable prompt must still be visible to /state")
            XCTAssertEqual(consent?.delivered, false)
        }
    #endif

    func test_visibility_isReadThroughTheSchedulerSeam() async {
        let canDeliver: @Sendable () -> Bool = { true }
        let manager = NotificationManager(
            scheduler: FakeNotificationScheduler(status: .denied),
            canDeliver: canDeliver,
        )
        let visibility = await manager.notificationVisibility()
        XCTAssertEqual(visibility.authorization, .denied)
    }

    /// The presentation settings travel with the authorisation status, in one
    /// read. Carrying only the status is what made an authorised-but-invisible
    /// prompt indistinguishable from a healthy one.
    func test_visibility_carriesThePresentationSettings() async {
        let canDeliver: @Sendable () -> Bool = { true }
        let invisible = NotificationVisibility(
            authorization: .authorized,
            alert: .enabled,
            alertStyle: .none,
            timeSensitive: .disabled,
            scheduledDelivery: .enabled,
        )
        let manager = NotificationManager(
            scheduler: FakeNotificationScheduler(visibility: invisible),
            canDeliver: canDeliver,
        )
        let visibility = await manager.notificationVisibility()
        XCTAssertEqual(visibility, invisible)
    }

    /// The protocol default, which every real double overrides and so had no
    /// coverage. It is the safety net that keeps `UNUserNotificationCenter`
    /// out of headless contexts: a notifier with no notification centre must
    /// report "not asked" rather than reach for one.
    func test_appNotifyingDefault_reportsNotDetermined() async {
        struct BareNotifier: AppNotifying {
            func notify(title _: String, body _: String) {}
        }
        let visibility = await BareNotifier().notificationVisibility()
        XCTAssertEqual(visibility, .unread)
    }

    /// Without a real app bundle the notification centre aborts the process, so
    /// the same `canDeliver` guard that protects `setUp` and `notify` has to
    /// protect this read too. A default that reached for the real centre
    /// crashed every existing `PermissionsControllerTests` case with signal 6.
    func test_visibility_isUnreadWhenNotDeliverable() async {
        let canDeliver: @Sendable () -> Bool = { false }
        let manager = NotificationManager(
            scheduler: FakeNotificationScheduler(status: .authorized),
            canDeliver: canDeliver,
        )
        let visibility = await manager.notificationVisibility()
        XCTAssertEqual(visibility, .unread, "must not consult the centre without a bundle")
    }
}
