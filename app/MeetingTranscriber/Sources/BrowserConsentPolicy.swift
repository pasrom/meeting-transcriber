import Foundation

/// Pure decision logic for the browser-meeting "ask before recording" prompt
/// (issue #503). Native meeting apps auto-start; browser meetings prompt, and a
/// declined prompt must not re-appear on every poll while the user stays in the
/// call. This is the *prompt* policy — distinct from `PowerAssertionDetector`'s
/// 5 s detection debounce (`cooldownDuration`), which only entprellt detection.
///
/// The WebRTC power assertion keeps firing for the whole call, so `checkOnce()`
/// re-detects the same meeting every few seconds; the policy is asked *before*
/// prompting so a decline suppresses re-prompts for `cooldown` seconds instead
/// of spamming. Value type with an injected `now` so it is deterministically
/// testable (pattern: `WatchLoopEndPolicy`, `ManualRecordingMonitorPolicy`).
struct BrowserConsentPolicy {
    /// How long an explicit "no" suppresses the next question. Long, because
    /// the user answered: asking again while they are still in the same call
    /// is the behaviour that turns a working prompt into nagging.
    let declineCooldown: TimeInterval
    /// How long an unanswered prompt suppresses the next question. Short,
    /// because silence is not a refusal — the user was away from the screen,
    /// and the next call must be able to ask again (issue #543).
    /// Both are independent of `NotificationManager.consentPromptTimeout`,
    /// which is how long a single question stays open.
    let expiryCooldown: TimeInterval
    /// Per-app instant until which prompting is suppressed after a decline.
    private var suppressedUntil: [String: Date] = [:]

    enum Decision: Equatable {
        /// No active suppression — prompt the user.
        case ask
        /// A recent decline still suppresses this app until the given instant.
        case suppressed(until: Date)
        /// The user answered "Never for this app". Unlike `.suppressed` this
        /// carries no instant, because it does not expire.
        case denied
    }

    init(declineCooldown: TimeInterval = 600, expiryCooldown: TimeInterval = 60) {
        self.declineCooldown = declineCooldown
        self.expiryCooldown = expiryCooldown
    }

    /// Whether to prompt for `app` at `now`.
    ///
    /// One function rather than a deny check in front of a cooldown check, so
    /// "will this app be prompted?" has a single answer and the precedence
    /// between the two is pinned by a unit test instead of only by an
    /// integration test through the live poll loop.
    ///
    /// `isDenied` is passed in rather than stored: a denial is persisted (see
    /// `ConsentDenyList`) while this policy is in-memory debounce state, and
    /// merging the two lifetimes would mean either persisting the cooldowns or
    /// losing the denials on relaunch.
    func decision(app: String, now: Date, isDenied: Bool = false) -> Decision {
        // Checked first, and without consulting `now`: a denial is an answer
        // about the app, so no amount of elapsed time may revive the question.
        if isDenied { return .denied }
        if let until = suppressedUntil[app], now < until {
            return .suppressed(until: until)
        }
        return .ask
    }

    /// Record an explicit refusal — suppress re-prompts for `declineCooldown`.
    mutating func recordDecline(app: String, now: Date) {
        suppressedUntil[app] = now.addingTimeInterval(declineCooldown)
    }

    /// Record that nobody answered — suppress re-prompts for the much shorter
    /// `expiryCooldown`, since no one refused anything.
    mutating func recordExpiry(app: String, now: Date) {
        suppressedUntil[app] = now.addingTimeInterval(expiryCooldown)
    }
}
