import Foundation
import Observation

/// Which capture source a caption came from. Distinct from the displayed
/// speaker label — the channel identifies the audio source, the label is
/// resolved live by matching the speech against the enrolled
/// `speakers.json` registry (or falls back to `LiveCaptionsState.micLabel`
/// / `.appLabel` when no match is confident enough). String raw values
/// double as the RPC wire format — the
/// `/state.liveCaptions.recentFinals[].channel` JSON field carries
/// `"mic"` / `"app"` directly.
enum LiveCaptionChannel: String, Hashable, Codable {
    case mic
    case app
}

/// A finalised utterance with its source channel and rendered speaker label.
/// `speaker` is captured at finalize time: either the name returned by the
/// live speaker matcher, or the channel-default fallback when the
/// extracted embedding doesn't pass `SpeakerMatcher`'s threshold + margin.
/// Captured per-line so a rename in `speakers.json` after the line is
/// committed doesn't retroactively relabel it.
struct LiveCaptionLine: Hashable, Codable {
    let channel: LiveCaptionChannel
    let text: String
    let speaker: String
}

/// Observable state powering the live caption-bar overlay.
///
/// Hypothesis is per-channel because mic and app audio can speak
/// concurrently (you replying to a remote question), and one channel
/// overwriting the other would make the overlay flicker between them.
/// Finalised lines are merged into a single rolling buffer keyed by channel
/// so the overlay renders them in time order with stable speaker prefixes.
///
/// Reset semantics: `clear()` is called by `LiveTranscriptionController.prepareForNextRecording()`
/// at the start of every new recording so the overlay doesn't carry over text
/// from a prior session.
@Observable
@MainActor
final class LiveCaptionsState {
    /// Display label for the local-mic channel when live speaker matching
    /// doesn't return a confident name (unknown voice). Defaults to `"Me"`
    /// to match `PipelineQueue.micLabel`'s batch default.
    let micLabel: String

    /// Display label for the meeting-app audio channel when live speaker
    /// matching doesn't return a confident name (unknown remote speaker).
    let appLabel: String

    init(micLabel: String = "Me", appLabel: String = "Remote", clock: any Clock<Duration> = ContinuousClock()) {
        self.micLabel = micLabel
        self.appLabel = appLabel
        self.clock = clock
    }

    private(set) var hypothesisMic: String = ""
    private(set) var hypothesisApp: String = ""

    /// Last few finalised utterances across both channels, oldest first.
    /// Capped at `maxFinalsKept`.
    private(set) var recentFinals: [LiveCaptionLine] = []

    /// Human label of the resolved live-caption backend, set by the controller
    /// once it builds the pipelines (e.g. "Nemotron · DE", "Parakeet EOU · EN",
    /// "Re-transcribe"). Nil when captions aren't active. Surfaced in the overlay
    /// so the user sees which engine actually drives captions — including a
    /// silent re-transcribe fallback.
    private(set) var activeBackend: String?

    /// Set by the controller after it resolves + builds the caption pipelines.
    func setActiveBackend(_ label: String?) {
        activeBackend = label
    }

    /// Size preset the overlay renders at. Lives here rather than being read
    /// from `AppSettings` by the view because the overlay is hosted in a panel
    /// that has no settings object, and `LiveCaptionsWindowController` has to
    /// resize that panel in the same step anyway: it pushes the preset through
    /// `setSize` so font and frame never disagree.
    private(set) var size: LiveCaptionsSize = .medium

    func setSize(_ size: LiveCaptionsSize) {
        self.size = size
    }

    /// Cap on `recentFinals` length. 2 keeps the bar at most two prior lines
    /// plus the two live hypothesis rows on top.
    static let maxFinalsKept = 2

    /// Seconds after the last event before the overlay starts fading out.
    static let fadeStartSeconds: TimeInterval = 2.0
    /// Seconds after the last event at which the overlay is fully transparent.
    static let fadeEndSeconds: TimeInterval = 4.0
    /// Seconds after the last event at which content is auto-cleared so the
    /// overlay collapses to nothing (panel itself stays mounted, just empty).
    static let autoClearSeconds: TimeInterval = 5.0

    private let clock: any Clock<Duration>
    /// Target opacity: the overlay animates to transparent when true.
    private(set) var faded = false

    private var silenceTask: Task<Void, Never>?

    func applyPartial(_ text: String, channel: LiveCaptionChannel) {
        switch channel {
        case .mic: hypothesisMic = text
        case .app: hypothesisApp = text
        }
        scheduleSilence()
    }

    func applyFinalized(_ text: String, channel: LiveCaptionChannel, speaker: String) {
        switch channel {
        case .mic: hypothesisMic = ""
        case .app: hypothesisApp = ""
        }
        recentFinals.append(LiveCaptionLine(channel: channel, text: text, speaker: speaker))
        if recentFinals.count > Self.maxFinalsKept {
            recentFinals.removeFirst(recentFinals.count - Self.maxFinalsKept)
        }
        scheduleSilence()
    }

    /// Convenience: speaker defaults to the channel label. Used by tests
    /// and as a fallback path when the live matcher isn't wired in.
    func applyFinalized(_ text: String, channel: LiveCaptionChannel) {
        applyFinalized(text, channel: channel, speaker: label(for: channel))
    }

    func label(for channel: LiveCaptionChannel) -> String {
        switch channel {
        case .mic: micLabel
        case .app: appLabel
        }
    }

    func clear() {
        silenceTask?.cancel()
        silenceTask = nil
        faded = false
        hypothesisMic = ""
        hypothesisApp = ""
        recentFinals.removeAll()
    }

    private func scheduleSilence() {
        silenceTask?.cancel()
        faded = false
        func schedule(on clock: some Clock<Duration>) {
            let fadeDeadline = clock.now.advanced(by: .seconds(Self.fadeStartSeconds))
            let clearDeadline = clock.now.advanced(by: .seconds(Self.autoClearSeconds))
            silenceTask = Task { @MainActor [weak self] in
                try? await clock.sleep(until: fadeDeadline, tolerance: nil)
                guard !Task.isCancelled else { return }
                self?.faded = true
                try? await clock.sleep(until: clearDeadline, tolerance: nil)
                guard !Task.isCancelled else { return }
                self?.clear()
            }
        }
        let silenceClock = clock
        schedule(on: silenceClock)
    }

    /// True when there's anything to show.
    var hasContent: Bool {
        !hypothesisMic.isEmpty
            || !hypothesisApp.isEmpty
            || !recentFinals.isEmpty
    }
}
