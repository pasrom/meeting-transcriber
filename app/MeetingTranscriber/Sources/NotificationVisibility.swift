import UserNotifications

/// What the notification centre will actually *do* with a posted notification,
/// as opposed to whether the app is merely allowed to post one.
///
/// Authorisation is the only part of this the app used to read, and it is the
/// part that lies: a user can be `.authorized` with the alert style set to None,
/// or with Time Sensitive switched off for this app, and then the
/// browser-meeting consent prompt is never seen. It expires as a decline, a
/// cooldown starts, and the feature is silently dead while every
/// authorisation-based check reports health.
///
/// Read as one snapshot (a single `notificationSettings()` call) so the fields
/// can't disagree with each other, and modelled as a value type because
/// `UNNotificationSettings` has no public initialiser: the decision logic in
/// `BrowserConsentReadiness` would otherwise be untestable.
struct NotificationVisibility: Equatable {
    /// Whether the app may post at all.
    let authorization: UNAuthorizationStatus
    /// Whether alerts are enabled for the app.
    let alert: UNNotificationSetting
    /// How an alert is presented. `.none` means Notification Center only: no
    /// banner appears, so a prompt with a deadline expires unseen.
    let alertStyle: UNAlertStyle
    /// Whether the app may post `.timeSensitive` notifications. This is what
    /// carries the consent prompt through Focus and Do Not Disturb.
    let timeSensitive: UNNotificationSetting
    /// Whether delivery is batched into the scheduled summary. It does not get
    /// its own verdict: `.timeSensitive` bypasses the summary too, so the fix is
    /// the same switch. Carried for diagnostics, which is how the original field
    /// report was pinned down.
    let scheduledDelivery: UNNotificationSetting

    /// Nothing read yet — the pre-check placeholder and the default for
    /// notifiers with no real notification centre behind them. Deliberately
    /// pessimistic on every setting except authorisation, which is genuinely
    /// unknown rather than denied.
    static let unread = Self(
        authorization: .notDetermined,
        alert: .notSupported,
        alertStyle: .none,
        timeSensitive: .notSupported,
        scheduledDelivery: .notSupported,
    )
}

extension NotificationVisibility {
    /// One line for the diagnostics log, in the same names `/state` uses (the
    /// tables below). Only the system's own enum values, nothing about the user.
    var logDescription: String {
        "authorization=\(authorization.rpcValue) alert=\(alert.rpcValue) alertStyle=\(alertStyle.rpcValue) "
            + "timeSensitive=\(timeSensitive.rpcValue) scheduledDelivery=\(scheduledDelivery.rpcValue)"
    }
}

extension UNAuthorizationStatus {
    /// Stable name for the authorisation status, shared by two readers: the
    /// debug RPC `/state.permissionHealth` snapshot and the persisted
    /// `notification_settings` diagnostics line. Renaming a value breaks both,
    /// a driver script asserting on `/state` and anyone reading old logs.
    /// Hand-written rather than derived from `rawValue` so the name cannot
    /// silently shift if Apple renumbers the enum. Lives here, outside any
    /// `#if`, because the log line exists in both build variants.
    var rpcValue: String {
        switch self {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        @unknown default: "unknown"
        }
    }
}

extension UNNotificationSetting {
    /// Stable name for the presentation settings that decide whether a
    /// notification is seen. Shared by `/state` and the diagnostics log like
    /// the authorisation table above, and hand-written for the same reason.
    var rpcValue: String {
        switch self {
        case .notSupported: "notSupported"
        case .disabled: "disabled"
        case .enabled: "enabled"
        @unknown default: "unknown"
        }
    }
}

extension UNAlertStyle {
    /// Stable name for the alert style, shared by `/state` and the diagnostics
    /// log like the tables above. "none" is the interesting one: it means
    /// Notification Center only, no banner, which is how an authorised app can
    /// still never show a notification with a deadline.
    var rpcValue: String {
        switch self {
        case .none: "none"
        case .banner: "banner"
        case .alert: "alert"
        @unknown default: "unknown"
        }
    }
}
