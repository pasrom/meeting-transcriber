@testable import MeetingTranscriber
import UserNotifications
import XCTest

/// That the notification diagnostics lines are written, and at the point they
/// claim to be: on every notification the guard drops, and on every request
/// handed to the notification centre, for plain notifications and for the
/// browser-meeting consent prompt alike.
@MainActor
final class NotificationManagerLoggingTests: XCTestCase {
    private func makeManager() -> (NotificationManager, FakeNotificationScheduler, RecordingDiagnostics) {
        let scheduler = FakeNotificationScheduler()
        let log = RecordingDiagnostics()
        let manager = NotificationManager(scheduler: scheduler, canDeliver: { true }, log: log)
        return (manager, scheduler, log)
    }

    func testADroppedNotificationIsLoggedWithItsReason() {
        let (manager, scheduler, log) = makeManager()

        manager.notify(title: "Capture Channel Silent", body: "body", urgency: .timeSensitive)

        XCTAssertTrue(scheduler.added.isEmpty, "precondition: not set up, so nothing is posted")
        XCTAssertEqual(log.lines(.warning, startingWith: "notification_dropped"), ["notification_dropped reason=not_set_up"])
        XCTAssertTrue(log.lines(.notice, startingWith: "notification_posted").isEmpty)
    }

    func testAPostedNotificationIsLoggedUnderTheIdItWasPostedWith() throws {
        let (manager, scheduler, log) = makeManager()
        manager.setUp()

        manager.notify(title: "Capture Channel Silent", body: "body", urgency: .timeSensitive)

        let request = try XCTUnwrap(scheduler.added.first)
        XCTAssertEqual(
            log.lines(.notice, startingWith: "notification_posted"),
            ["notification_posted id=\(request.identifier) urgency=timeSensitive"],
        )
        XCTAssertTrue(log.lines(.warning, startingWith: "notification_dropped").isEmpty)
    }

    func testADroppedConsentPromptIsLogged() async {
        let (manager, _, log) = makeManager()

        let answer = await manager.askToRecord(title: "Record browser meeting?", body: "A meeting is active.")

        XCTAssertEqual(answer, .declined, "precondition: an undeliverable prompt declines")
        XCTAssertEqual(log.lines(.warning, startingWith: "notification_dropped"), ["notification_dropped reason=not_set_up"])
    }

    func testAPostedConsentPromptIsLoggedUnderItsId() async throws {
        let (manager, scheduler, log) = makeManager()
        manager.setUp()
        let task = Task { await manager.askToRecord(title: "Record browser meeting?", body: "A meeting is active.") }

        await waitFor(!scheduler.added.isEmpty)
        let request = try XCTUnwrap(scheduler.added.first)
        manager.resolveConsent(responseIdentifier: request.identifier, actionIdentifier: NotificationManager.ignoreActionID)
        _ = await task.value

        XCTAssertEqual(
            log.lines(.notice, startingWith: "notification_posted"),
            ["notification_posted id=\(request.identifier) urgency=timeSensitive"],
        )
    }
}
