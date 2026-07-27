import UserNotifications

/// Whether a browser-meeting consent prompt can actually reach the user.
///
/// Browser meetings (issue #503) never auto-record: detection parks a prompt and
/// waits for an answer. That prompt is a `UNUserNotification`, which makes the
/// notification permission a hard dependency of the feature rather than a
/// nicety. With notifications denied the failure is silent and total: detection
/// fires, the prompt parks where nobody can see it, it times out as a decline
/// after `NotificationManager.consentPromptTimeout`, a cooldown starts, and the
/// cycle repeats forever while the toggle still reads as on.
///
/// Nothing else in the app notices. `NotificationManager.canDeliver` only checks
/// that an app bundle exists, `PermissionHealthCheck` covers microphone, screen
/// recording and accessibility, and warning the user with a notification would
/// be self-defeating. Hence a Settings-side warning, decided here so the rule is
/// testable without a notification centre.
enum BrowserConsentReadiness: Equatable {
    /// Browser watching is off, so there is nothing to warn about even if
    /// notifications are denied.
    case disabled
    /// The prompt will be shown.
    case ready
    /// Notifications are denied. The prompt can never appear.
    case denied
    /// Not asked yet, so no prompt can be shown either.
    case undetermined
    /// Provisional authorisation: delivered quietly to Notification Center with
    /// no banner. A prompt that expires on a timer is effectively invisible.
    case quiet

    static func evaluate(
        browserMeetingsEnabled: Bool,
        authorization: UNAuthorizationStatus,
    ) -> Self {
        guard browserMeetingsEnabled else { return .disabled }
        // An unknown future status falls in with `.quiet` rather than `.ready`:
        // assuming a state this build has never seen can show a banner would
        // turn a new OS behaviour into a silently dead feature, while the
        // reverse only costs a warning that turns out to be unnecessary.
        switch authorization {
        case .authorized, .ephemeral: return .ready
        case .denied: return .denied
        case .notDetermined: return .undetermined
        case .provisional: return .quiet
        @unknown default: return .quiet
        }
    }

    /// User-facing explanation, or nil when the prompt will be visible. Each
    /// case names the consequence (no recording) and not just the state,
    /// because "allow notifications" on its own reads as optional polish.
    var warning: String? {
        switch self {
        case .disabled, .ready:
            nil

        case .denied:
            "Notifications are turned off for Meeting Transcriber, so the "
                + "\"record this meeting?\" prompt cannot appear and browser meetings "
                + "will never be recorded. Allow notifications in System Settings."

        case .undetermined:
            "Meeting Transcriber has not been allowed to send notifications yet. "
                + "Until it is, the \"record this meeting?\" prompt cannot appear and "
                + "browser meetings will never be recorded."

        case .quiet:
            "Notifications are delivered quietly, so the \"record this meeting?\" "
                + "prompt arrives without a banner and usually expires unanswered. "
                + "Browser meetings will rarely be recorded. Allow banners in System Settings."
        }
    }
}
