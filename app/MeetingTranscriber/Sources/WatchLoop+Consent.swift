import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoopConsent")

/// Browser-meeting recording-consent gate (issue #503), split out of `WatchLoop`
/// to keep its body under the line-length cap. Only patterns with
/// `requiresRecordingConsent` reach it; native meetings auto-start unchanged.
///
/// The answer is awaited in its own task rather than inline in the poll loop
/// (issue #543). Inline, `detector.checkOnce()` was not called at all while a
/// prompt was open — up to `NotificationManager.consentPromptTimeout` of not
/// looking, during which a Teams or Zoom call that needs no consent went
/// unnoticed. Google Meet raises the same WebRTC assertion on a page you cannot
/// even join, so a stale link was enough to freeze native detection for a
/// minute.
extension WatchLoop {
    /// Whether this meeting has to wait for the user instead of recording now.
    /// Returns immediately in every case.
    ///
    /// True also covers "we are already asking about this app" and "a recent
    /// decline still suppresses the question" — both reasons to skip the
    /// meeting, neither a reason to ask again.
    func requestConsentIfNeeded(for meeting: DetectedMeeting) -> Bool {
        guard meeting.pattern.requiresRecordingConsent else { return false }
        // One question at a time. The WebRTC assertion re-detects the same call
        // every poll, so without this the loop would post a fresh prompt every
        // few seconds while the first one is still on screen.
        guard pendingConsentApp == nil else { return true }

        let app = meeting.pattern.appName
        // "Never for this app" outranks every cooldown: it is an answer about
        // the app, so unlike a decline it never expires. Checked before the
        // policy so no amount of elapsed time can revive the question.
        guard !denyListStore.isDenied(app) else {
            detector.reset(appName: app)
            return true
        }

        guard case .ask = consentPolicy.decision(app: app, now: nowProvider()) else {
            detector.reset(appName: app) // re-detect after the debounce
            return true
        }

        pendingConsentApp = app
        // `app` is already the concrete browser: a browser meeting is carried
        // under the process that held the assertion, so the debounce above and
        // the name below refer to the same one browser. `ownerName` is kept as
        // the source with a fallback because it is the value the detector read
        // straight off the assertion, and an empty identity would otherwise
        // produce a prompt naming nothing at all.
        let browserName = meeting.ownerName.isEmpty ? app : meeting.ownerName
        consentTask = Task { [weak self] in
            guard let self else { return }
            let answer = await notifier.askToRecord(
                title: "Record browser meeting?",
                body: "A meeting is active in \(browserName).",
            )
            finishConsent(for: meeting, answer: answer)
        }
        return true
    }

    /// Take the approved meeting, if any, clearing it. The poll loop is the
    /// only caller: recordings start there and nowhere else, so two of them
    /// cannot overlap.
    func takeApprovedConsentMeeting() -> DetectedMeeting? {
        defer { approvedConsentMeeting = nil }
        return approvedConsentMeeting
    }

    /// Answer a parked prompt as a decline, for `stop()`. Routed through the
    /// notifier so the real prompt's parked continuation completes; without it
    /// the question would linger for the rest of its timeout.
    func declineParkedConsent() {
        guard pendingConsentApp != nil else { return }
        _ = notifier.resolveBrowserConsent(granted: false)
        // Cleared regardless of whether anything was waiting: a notifier with
        // no coordinator behind it never resolves, and a prompt stuck
        // "pending" forever would silence every future question.
        clearConsentState()
    }

    /// Land the user's answer. Main-actor isolated like the rest of
    /// `WatchLoop`, so it cannot race the poll loop's reads.
    private func finishConsent(for meeting: DetectedMeeting, answer: ConsentAnswer) {
        let app = meeting.pattern.appName
        clearConsentState()

        guard answer.isGranted else {
            // A refusal and a prompt nobody saw are different facts, and the
            // cooldown treats them differently: ten minutes of quiet after a
            // no, one minute after silence. Never is a third fact and outlives
            // both, and takes no cooldown of its own.
            switch answer {
            case .expired:
                consentPolicy.recordExpiry(app: app, now: nowProvider())

            case .never:
                // No decline cooldown alongside it. The denial already
                // suppresses, and a cooldown would outlive a Settings "Remove"
                // by up to ten minutes, so undoing a mistaken Never would
                // silently keep doing nothing.
                denyListStore.deny(app)

            default:
                consentPolicy.recordDecline(app: app, now: nowProvider())
            }
            detector.reset(appName: app)
            return
        }
        // Minutes can pass between prompt and click, and watching may have been
        // switched off in between — recording then would be recording without
        // having been asked to watch at all.
        guard isActive else {
            logger.info("Consent granted for \(app, privacy: .public) after watching stopped — ignoring")
            return
        }
        // The call itself may also have ended while the question sat there.
        guard detector.isMeetingActive(meeting) else {
            detector.reset(appName: app)
            return
        }
        approvedConsentMeeting = meeting
    }
}
