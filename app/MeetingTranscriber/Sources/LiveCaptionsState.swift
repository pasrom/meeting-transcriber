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
/// `speaker` starts as the channel-default fallback and can be replaced by
/// the live match for this line. Later registry renames do not relabel it.
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

    /// Shortest time a finalized line stays fully visible.
    static let minimumReadingHold: TimeInterval = 4.0
    /// Reading time per word of a finalized line, above `minimumReadingHold`.
    static let readingSecondsPerWord: TimeInterval = 0.3
    /// Longest hold: 20 words at 0.3 s, about what two lines show. EOU can finalize 100+ words at once,
    /// and holding for words already clipped off the row kept the bar up 30 s after speech.
    static let maximumReadingHold: TimeInterval = 6.0
    /// A hypothesis unchanged this long no longer holds the fade: a backend can
    /// drop a final (empty or failed decode) without sending any event.
    static let abandonedHypothesisSeconds: TimeInterval = 5.0
    /// Length of the fade, after which the bar clears.
    static let fadeDuration: TimeInterval = 2.0

    private let clock: any Clock<Duration>
    /// Target opacity: the overlay animates to transparent when true.
    private(set) var faded = false

    /// Monotonic identity for late speaker matches; never reused after clear.
    private var finalSequence = 0
    private var silenceTask: Task<Void, Never>?
    private var remainingReadingTime: (() -> Duration)?

    func applyPartial(_ text: String, channel: LiveCaptionChannel) {
        switch channel {
        case .mic: hypothesisMic = text
        case .app: hypothesisApp = text
        }
        scheduleSilence()
    }

    @discardableResult
    func applyFinalized(_ text: String, channel: LiveCaptionChannel, speaker: String) -> Int {
        switch channel {
        case .mic: hypothesisMic = ""
        case .app: hypothesisApp = ""
        }
        finalSequence += 1
        recentFinals.append(LiveCaptionLine(channel: channel, text: text, speaker: speaker))
        if recentFinals.count > Self.maxFinalsKept {
            recentFinals.removeFirst(recentFinals.count - Self.maxFinalsKept)
        }
        setReadingDeadline(for: text)
        scheduleSilence()
        return finalSequence
    }

    /// A late match changes only its retained line, never a newer hypothesis or reading deadline.
    func updateSpeaker(_ speaker: String, forFinal sequence: Int) {
        let distance = finalSequence - sequence
        guard distance >= 0, distance < recentFinals.count else { return }
        let index = recentFinals.count - 1 - distance
        let line = recentFinals[index]
        recentFinals[index] = LiveCaptionLine(channel: line.channel, text: line.text, speaker: speaker)
    }

    /// Convenience: speaker defaults to the channel label. Used by tests
    /// and as a fallback path when the live matcher isn't wired in.
    @discardableResult
    func applyFinalized(_ text: String, channel: LiveCaptionChannel) -> Int {
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
        remainingReadingTime = nil
    }

    private func setReadingDeadline(for text: String) {
        let words = Double(text.split(whereSeparator: \.isWhitespace).count)
        let seconds = min(Self.maximumReadingHold, max(Self.minimumReadingHold, words * Self.readingSecondsPerWord))
        func remember(on clock: some Clock<Duration>) {
            let deadline = clock.now.advanced(by: .seconds(seconds))
            remainingReadingTime = { max(.zero, clock.now.duration(to: deadline)) }
        }
        // The copy is needed: `remember(on: clock)` does not compile on the @Observable property.
        let readingClock = clock
        remember(on: readingClock)
    }

    private func scheduleSilence() {
        silenceTask?.cancel()
        silenceTask = nil
        faded = false
        guard hasContent else { return }
        let reading = remainingReadingTime?() ?? .zero
        // Every partial reschedules, so this hold only elapses once the hypothesis stops updating.
        let hold = hypothesisMic.isEmpty && hypothesisApp.isEmpty
            ? reading
            : max(reading, .seconds(Self.abandonedHypothesisSeconds))
        func schedule(on clock: some Clock<Duration>) {
            let fadeDeadline = clock.now.advanced(by: hold)
            silenceTask = Task { @MainActor [weak self] in
                try? await clock.sleep(until: fadeDeadline, tolerance: nil)
                guard !Task.isCancelled else { return }
                self?.faded = true
                let clearDeadline = clock.now.advanced(by: .seconds(Self.fadeDuration))
                try? await clock.sleep(until: clearDeadline, tolerance: nil)
                guard !Task.isCancelled else { return }
                self?.clear()
            }
        }
        // The copy is needed: `schedule(on: clock)` does not compile on the @Observable property.
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
