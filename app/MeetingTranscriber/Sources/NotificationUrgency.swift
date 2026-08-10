import UserNotifications

/// How urgently a notification has to reach the user.
///
/// Two cases rather than the five `UNNotificationInterruptionLevel` offers,
/// because only one question is being answered: may this notification break
/// through a Focus mode. `.critical` needs its own Apple-granted entitlement
/// and rings through a muted device, and `.passive` is quieter than anything
/// this app posts, so neither is a policy the app has and neither is
/// expressible here.
enum NotificationUrgency {
    /// A banner the user reads whenever they get round to it. Suppressed by any
    /// Focus mode, which is right for anything without a deadline.
    case standard

    /// Breaks through Focus. Reserved for a failure the user can still act on
    /// while it is happening.
    ///
    /// Honoured only when the bundle carries
    /// `com.apple.developer.usernotifications.time-sensitive`. Do not add that
    /// key to `Entitlements/*.entitlements`; `scripts/lib/signing.sh` documents
    /// why and injects it from `prepare_signing` instead.
    ///
    /// Asking for it is unconditionally safe: without the entitlement macOS
    /// treats the request as an ordinary banner, so an unprovisioned or
    /// fork-built bundle degrades rather than failing. Today the notarized
    /// Homebrew release is the build that carries it and the sandboxed App
    /// Store one is not, which is a packaging gap this type cannot close.
    case timeSensitive

    var interruptionLevel: UNNotificationInterruptionLevel {
        switch self {
        case .standard: .active
        case .timeSensitive: .timeSensitive
        }
    }
}
