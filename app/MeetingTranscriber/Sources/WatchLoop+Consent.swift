import Foundation

/// Browser-meeting recording-consent gate (issue #503), split out of `WatchLoop`
/// to keep its body under the line-length cap. Only patterns with
/// `requiresRecordingConsent` reach it; native meetings auto-start unchanged.
extension WatchLoop {
    /// Whether to skip recording this detected meeting because it needs consent
    /// and the user declined (or a recent decline still suppresses the prompt).
    /// Resets the detector on a skip so it re-detects after its debounce.
    func shouldDeferForConsent(_ meeting: DetectedMeeting) async -> Bool {
        guard meeting.pattern.requiresRecordingConsent else { return false }
        if await grantRecordingConsent(for: meeting) { return false }
        detector.reset(appName: meeting.pattern.appName)
        return true
    }

    /// Prompt (via the notifier) unless a recent decline still suppresses it,
    /// then confirm the call is still active before starting — minutes can pass
    /// between prompt and click. True only when recording should start.
    private func grantRecordingConsent(for meeting: DetectedMeeting) async -> Bool {
        let app = meeting.pattern.appName
        guard case .ask = consentPolicy.decision(app: app, now: nowProvider()) else {
            return false // still in decline cooldown → don't prompt, don't record
        }
        let granted = await notifier.askToRecord(
            title: "Record browser meeting?",
            body: "A meeting is active in \(app).",
        )
        guard granted else {
            consentPolicy.recordDecline(app: app, now: nowProvider())
            return false
        }
        // The prompt is async; re-check the call didn't end while it was open.
        return detector.isMeetingActive(meeting)
    }
}
