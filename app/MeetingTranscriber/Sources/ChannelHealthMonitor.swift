import Foundation

/// Which audio capture channel a `ChannelHealthMonitor` event refers to.
enum AudioChannel: Hashable {
    case mic
    case app
}

/// Events emitted by `ChannelHealthMonitor.update(...)`.
///
/// `.started` fires once when one channel has been silent (≤ silenceThreshold) while
/// the other has been carrying speech (≥ speechThreshold) continuously for at least
/// `debounceSeconds`. `.recovered` fires once when the dead channel returns above
/// the speech threshold.
enum ChannelHealthEvent: Equatable {
    case started(channel: AudioChannel, quietSince: Date)
    case recovered(channel: AudioChannel)
}

/// Pure state machine that detects *asymmetric* capture silence — one channel
/// dead while the other still carries audio — and debounces it to avoid noisy
/// notifications during legitimate pauses.
///
/// Callers feed in instantaneous per-channel dBFS levels at any cadence; the
/// monitor returns at most one event per `update(...)` call.
struct ChannelHealthMonitor {
    let silenceThresholdDBFS: Double
    let speechThresholdDBFS: Double
    let debounceSeconds: TimeInterval

    /// Which channels this recording actually opened. A channel that was never
    /// opened reads as permanently silent, and reporting that as a dead channel
    /// is a guaranteed false positive rather than an unlikely one.
    let channels: CapturedChannels

    private var episode: Episode?

    private struct Episode {
        var channel: AudioChannel
        var quietSince: Date
        var started: Bool
    }

    init(
        silenceThresholdDBFS: Double = -60,
        speechThresholdDBFS: Double = -50,
        debounceSeconds: TimeInterval = 90,
        channels: CapturedChannels = .micAndApp,
    ) {
        self.silenceThresholdDBFS = silenceThresholdDBFS
        self.speechThresholdDBFS = speechThresholdDBFS
        self.debounceSeconds = debounceSeconds
        self.channels = channels
    }

    mutating func update(micDBFS: Double, appDBFS: Double, now: Date) -> ChannelHealthEvent? {
        let asymmetric = asymmetricChannel(micDBFS: micDBFS, appDBFS: appDBFS)

        guard let channel = asymmetric else {
            return handleNonAsymmetricTick(micDBFS: micDBFS, appDBFS: appDBFS)
        }

        if episode?.channel != channel {
            // Channel switch. If the outgoing episode was latched (`.started`
            // already fired), surface its recovery before tracking the new
            // channel — otherwise downstream consumers (UI flags, notifier)
            // never learn the old channel came back online.
            let recoveryEvent: ChannelHealthEvent? = if let old = episode, old.started {
                .recovered(channel: old.channel)
            } else {
                nil
            }
            episode = Episode(channel: channel, quietSince: now, started: false)
            return recoveryEvent
        }

        guard var current = episode, !current.started else { return nil }
        if now.timeIntervalSince(current.quietSince) >= debounceSeconds {
            current.started = true
            episode = current
            return .started(channel: channel, quietSince: current.quietSince)
        }
        return nil
    }

    mutating func reset() {
        episode = nil
    }

    // MARK: - Internals

    /// A channel only counts as the silent side of an asymmetry when the
    /// recording opened it. Without that guard a microphone-only recording
    /// reports its absent app channel as dead the moment anyone speaks, and an
    /// app-only recording does the same for the microphone the user switched
    /// off — in both cases permanently, since recovery needs the channel to
    /// rise above the speech threshold and a channel that does not exist never
    /// will.
    private func asymmetricChannel(micDBFS: Double, appDBFS: Double) -> AudioChannel? {
        let micSilent = micDBFS <= silenceThresholdDBFS
        let micSpeech = micDBFS >= speechThresholdDBFS
        let appSilent = appDBFS <= silenceThresholdDBFS
        let appSpeech = appDBFS >= speechThresholdDBFS

        if channels.mic, micSilent, appSpeech { return .mic }
        if channels.app, appSilent, micSpeech { return .app }
        return nil
    }

    /// Called when neither side is unambiguously asymmetric (e.g. a level
    /// fell into the dead zone between `silenceThresholdDBFS` and
    /// `speechThresholdDBFS`). Hysteresis: an active episode only resolves
    /// when the channel believed to be silent crosses back above
    /// `speechThresholdDBFS`. Transient dips (natural speech pauses on the
    /// active side, or borderline noise on the silent side) keep the
    /// debounce timer running instead of resetting it on every wobble.
    private mutating func handleNonAsymmetricTick(micDBFS: Double, appDBFS: Double) -> ChannelHealthEvent? {
        guard let current = episode else { return nil }
        let silentSideRecovered: Bool = switch current.channel {
        case .mic: micDBFS >= speechThresholdDBFS
        case .app: appDBFS >= speechThresholdDBFS
        }
        guard silentSideRecovered else { return nil }
        let wasStarted = current.started
        episode = nil
        return wasStarted ? .recovered(channel: current.channel) : nil
    }
}
