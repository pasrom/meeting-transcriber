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
