import os.log
import UserNotifications

/// Port over the slice of `UNUserNotificationCenter` that `NotificationManager`
/// uses (add / register categories / set delegate / request permission), so its
/// posting + registration behaviour is testable against a fake. The real center
/// needs a proper app bundle and can't run in `swift test`, which is exactly why
/// the behaviour has to be driven through this seam.
///
/// The concrete `SystemNotificationScheduler` is the thin, deliberately-untested
/// adapter — its pass-throughs are exercised by the e2e-app lane's real
/// notifications, which unit coverage can't reach.
protocol NotificationScheduling: AnyObject, Sendable {
    func add(_ request: UNNotificationRequest)
    func setCategories(_ categories: Set<UNNotificationCategory>)
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func requestAuthorization()
}

/// Real adapter: forwards to `UNUserNotificationCenter.current()`. Sendable (its
/// only state is a `Logger`), so its `requestAuthorization` completion — a
/// `@Sendable` closure — can reference it.
final class SystemNotificationScheduler: NotificationScheduling, Sendable {
    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NotificationScheduler")

    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request)
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        UNUserNotificationCenter.current().delegate = delegate
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                self.logger.error("Notification permission error: \(error.localizedDescription, privacy: .public)")
            }
            if !granted {
                self.logger.warning("Notification permission denied")
            }
        }
    }
}
