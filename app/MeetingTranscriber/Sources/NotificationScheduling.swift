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

    /// How a posted notification would actually be presented, queried rather
    /// than remembered from the `requestAuthorization` callback: the user can
    /// change any of it in System Settings at any time, and browser-meeting
    /// consent silently stops working when they do (see
    /// `BrowserConsentReadiness`).
    func visibility() async -> NotificationVisibility
}

/// Real adapter: forwards to `UNUserNotificationCenter.current()`. Sendable (its
/// only state is a `Logger`), so its `requestAuthorization` completion — a
/// `@Sendable` closure — can reference it.
final class SystemNotificationScheduler: NotificationScheduling, Sendable {
    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NotificationScheduler")

    /// Completion-handler form, only for the error. The fire-and-forget
    /// overload discards it, so a rejected post looked exactly like a
    /// successful one from inside the app — and the consent prompt is the one
    /// notification where that difference decides whether a meeting is
    /// recorded. `.public` on the message: `localizedDescription`, never
    /// `String(describing:)`, which can carry a home-directory path.
    func add(_ request: UNNotificationRequest) {
        // The identifier is lifted out because `UNNotificationRequest` is not
        // Sendable and the completion is a `@Sendable` closure.
        let id = request.identifier
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            self.logger.error(
                """
                notification_post_failed id=\(id, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """,
            )
        }
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// One `notificationSettings()` read for every field, so the snapshot can't
    /// contradict itself. The mapping is the untestable part by construction:
    /// `UNNotificationSettings` has no public initialiser, which is exactly why
    /// the port hands back a value type the decision logic can be tested on.
    func visibility() async -> NotificationVisibility {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationVisibility(
            authorization: settings.authorizationStatus,
            alert: settings.alertSetting,
            alertStyle: settings.alertStyle,
            timeSensitive: settings.timeSensitiveSetting,
            scheduledDelivery: settings.scheduledDeliverySetting,
        )
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
