import Foundation

/// How a browser-meeting consent prompt ended (issue #503).
///
/// Three outcomes, not two, because "no" and "nobody answered" are different
/// facts about the user and deserve different re-prompt behaviour (issue #543).
/// Collapsing them into a `Bool` meant an unanswered prompt — the normal case
/// for anyone who stepped away, and the *only* case before the prompt could
/// break through Focus — was recorded as a deliberate refusal.
///
/// Only `.granted` starts a recording. The distinction exists purely for
/// `BrowserConsentPolicy`, which suppresses the next question for longer after
/// a real refusal than after silence.
enum ConsentAnswer: Equatable {
    /// The user tapped Record.
    case granted
    /// The user said no: the Ignore action, a swipe-away dismiss, or a tap on
    /// the notification body. Also what a notifier with no prompt reports,
    /// since "we could not ask" must never record.
    case declined
    /// Nobody answered before `NotificationManager.consentPromptTimeout`.
    case expired
    /// The user said no *about this app*, not about this call: the "Never for
    /// this app" action. Distinct from `.declined` because a decline expires
    /// with the cooldown and this does not — it goes on `BrowserAppDenyList`
    /// and is only undone in Settings. Mapping it onto `.declined` would
    /// re-prompt ten minutes later, which is the thing the user just said no to.
    case never

    /// Whether a recording may start.
    var isGranted: Bool {
        self == .granted
    }
}
