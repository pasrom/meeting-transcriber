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
    /// How long after a decline the same app stays suppressed from re-prompting.
    /// Independent of `NotificationManager.consentPromptTimeout` (how long an
    /// unanswered prompt stays open) — they share a default value but are
    /// separate knobs.
    let cooldown: TimeInterval
    /// Per-app instant until which prompting is suppressed after a decline.
    private var suppressedUntil: [String: Date] = [:]

    enum Decision: Equatable {
        /// No active suppression — prompt the user.
        case ask
        /// A recent decline still suppresses this app until the given instant.
        case suppressed(until: Date)
    }

    init(cooldown: TimeInterval = 60) {
        self.cooldown = cooldown
    }

    /// Whether to prompt for `app` at `now`, or stay quiet after a recent decline.
    func decision(app: String, now: Date) -> Decision {
        if let until = suppressedUntil[app], now < until {
            return .suppressed(until: until)
        }
        return .ask
    }

    /// Record that the user declined (or the prompt timed out) — suppress
    /// re-prompts for this app for `cooldown` seconds.
    mutating func recordDecline(app: String, now: Date) {
        suppressedUntil[app] = now.addingTimeInterval(cooldown)
    }
}
