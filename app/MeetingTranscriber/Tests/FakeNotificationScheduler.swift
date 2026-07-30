import Foundation
@testable import MeetingTranscriber
import UserNotifications

/// Fake `NotificationScheduling` recording what `NotificationManager` posts and
/// registers, so posting + consent behaviour is testable without a real
/// `UNUserNotificationCenter` (which needs an app bundle absent in `swift test`).
/// Shared: two suites drive the same manager, and a protocol requirement added
/// in one place should not have to be implemented twice.
final class FakeNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [UNNotificationRequest] = []
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) weak var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var authRequested = false
    let reportedVisibility: NotificationVisibility

    /// Authorised and fully visible unless a test says otherwise, so a suite
    /// about posting doesn't have to spell out presentation settings it does
    /// not care about.
    convenience init(status: UNAuthorizationStatus = .authorized) {
        self.init(visibility: NotificationVisibility(
            authorization: status,
            alert: .enabled,
            alertStyle: .banner,
            timeSensitive: .enabled,
            scheduledDelivery: .disabled,
        ))
    }

    init(visibility: NotificationVisibility) {
        reportedVisibility = visibility
    }

    var added: [UNNotificationRequest] {
        lock.lock(); defer { lock.unlock() }; return _added
    }

    func add(_ request: UNNotificationRequest) {
        lock.lock(); _added.append(request); lock.unlock()
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        self.delegate = delegate
    }

    func requestAuthorization() {
        authRequested = true
    }

    // swiftlint:disable async_without_await
    func visibility() async -> NotificationVisibility {
        reportedVisibility
    }

    // swiftlint:enable async_without_await
}
