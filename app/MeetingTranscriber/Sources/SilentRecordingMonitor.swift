import Foundation

/// Event emitted by `SilentRecordingMonitor.update(...)` — at most one event
/// per call.
///
/// `.started` fires once when **both** capture channels have been below
/// `silenceThresholdDBFS` continuously for `debounceSeconds`. `.recovered`
/// fires once when either channel returns above `speechThresholdDBFS`, so
/// downstream consumers (UI flag, notifier) learn the recording is alive
/// again without polling for falsy reads.
enum SilentRecordingEvent: Equatable {
    case started(silenceSince: Date)
    case recovered
}

/// Pure state machine that catches the failure mode `ChannelHealthMonitor`
/// intentionally skips: a recording where **both** channels stay at the
/// noise floor for the entire session (e.g. AirPods HFP mode claims the
/// mic and Teams mixes app audio internally so the CATapDescription tap
/// sees only zero buffers — symmetric silence that
/// `ChannelHealthMonitor.asymmetricChannel` correctly ignores to avoid
/// false-positives during natural conversation pauses).
///
/// Callers feed in instantaneous per-channel dBFS at any cadence; the
/// monitor returns at most one event per `update(...)` call. Hysteresis:
/// a transient mid-zone read on one side (e.g. a borderline noise spike
/// on the mic during otherwise-silent app audio) keeps the debounce
/// timer running rather than resetting it — only **actual speech** on
/// either side proves the recording isn't dead and discards the
/// in-flight episode.
struct SilentRecordingMonitor {
    let silenceThresholdDBFS: Double
    let speechThresholdDBFS: Double
    let debounceSeconds: TimeInterval

    private var episode: Episode?

    private struct Episode {
        var silenceSince: Date
        var started: Bool
    }

    init(
        silenceThresholdDBFS: Double = -60,
        speechThresholdDBFS: Double = -50,
        debounceSeconds: TimeInterval = 90,
    ) {
        self.silenceThresholdDBFS = silenceThresholdDBFS
        self.speechThresholdDBFS = speechThresholdDBFS
        self.debounceSeconds = debounceSeconds
    }

    mutating func update(micDBFS: Double, appDBFS: Double, now: Date) -> SilentRecordingEvent? {
        let micSilent = micDBFS <= silenceThresholdDBFS
        let appSilent = appDBFS <= silenceThresholdDBFS
        let micSpeech = micDBFS >= speechThresholdDBFS
        let appSpeech = appDBFS >= speechThresholdDBFS

        if micSilent && appSilent {
            return handleBothSilent(now: now)
        }

        // Actual speech on either side — recording is alive; drop any in-flight
        // episode. Surfaces .recovered if we had previously latched.
        if micSpeech || appSpeech {
            return clearEpisode()
        }

        // Mid-zone on one or both sides: no positive proof the recording is
        // either silent or alive. Hysteresis: don't reset an in-flight
        // timer, but don't advance the latch either — just wait.
        return nil
    }

    mutating func reset() {
        episode = nil
    }

    // MARK: - Internals

    private mutating func handleBothSilent(now: Date) -> SilentRecordingEvent? {
        guard var current = episode else {
            episode = Episode(silenceSince: now, started: false)
            return nil
        }
        if current.started { return nil }
        if now.timeIntervalSince(current.silenceSince) >= debounceSeconds {
            current.started = true
            episode = current
            return .started(silenceSince: current.silenceSince)
        }
        return nil
    }

    private mutating func clearEpisode() -> SilentRecordingEvent? {
        guard let current = episode else { return nil }
        episode = nil
        return current.started ? .recovered : nil
    }
}
