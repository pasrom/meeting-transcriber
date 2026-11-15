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

    /// Language detection is visible even before either channel has caption text.
    private(set) var isDetectingLanguage = false

    func setDetectingLanguage(_ detecting: Bool) {
        isDetectingLanguage = detecting
        if detecting {
            silenceTask?.cancel()
            silenceTask = nil
            faded = false
        }
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

    /// Cap on `recentFinals` length. The overlay joins a speaker's lines into one
    /// row, so past the cap all but the newest two lines go at once: dropping one line
    /// at a time would re-wrap that row on every line. The second keeps a line before
    /// the newest for it to join and take its speaker from.
    static let maxFinalsKept = 6

    /// How long the lines of a finished turn stay above the next speaker's row.
    static let earlierTurnHold: TimeInterval = 4.0

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
    /// Sequence of the first final of the newest turn an expiry was scheduled for.
    private var scheduledTurnStart = 0
    /// Finals too short to match that take the speaker of the line before them.
    private var inheritingFinals: Set<Int> = []
    /// Finals whose speaker match is still running; the overlay keeps them in the row before them.
    private var awaitingSpeaker: Set<Int> = []
    /// Voice the change detector heard take over a channel: the live text shows it, and the next
    /// final on the channel takes it and ends it.
    private var voiceHints: [LiveCaptionChannel: String] = [:]
    /// The final that took a channel's voice hint; it does not inherit from the previous voice's line.
    private var voiceChangeLines: [LiveCaptionChannel: Int] = [:]
    /// Such a final too short to match: it takes the outcome of the next match on its channel.
    private var shortVoiceChangeLines: [LiveCaptionChannel: Int] = [:]
    private var remainingReadingTime: (() -> Duration)?

    func applyPartial(_ text: String, channel: LiveCaptionChannel) {
        switch channel {
        case .mic: hypothesisMic = text
        case .app: hypothesisApp = text
        }
        scheduleSilence()
    }

    @discardableResult
    func applyFinalized(
        _ text: String,
        channel: LiveCaptionChannel,
        speaker: String,
        awaitingSpeaker awaiting: Bool = false,
    ) -> Int {
        switch channel {
        case .mic: hypothesisMic = ""
        case .app: hypothesisApp = ""
        }
        finalSequence += 1
        let hinted = voiceHints.removeValue(forKey: channel)
        if hinted != nil {
            voiceChangeLines[channel] = finalSequence
        }
        let speaker = hinted ?? speaker
        recentFinals.append(LiveCaptionLine(channel: channel, text: text, speaker: speaker))
        if recentFinals.count > Self.maxFinalsKept {
            recentFinals.removeFirst(recentFinals.count - 2)
        }
        let firstKept = finalSequence - (recentFinals.count - 1)
        awaitingSpeaker = awaitingSpeaker.filter { $0 >= firstKept }
        if awaiting {
            awaitingSpeaker.insert(finalSequence)
        }
        setReadingDeadline(for: text)
        scheduleSilence()
        scheduleTurnExpiry()
        return finalSequence
    }

    /// A late match updates retained and inheriting lines without changing hypotheses or the reading deadline.
    func updateSpeaker(_ speaker: String, forFinal sequence: Int) {
        awaitingSpeaker.remove(sequence)
        guard let start = index(ofFinal: sequence) else { return }
        let channel = recentFinals[start].channel
        setSpeaker(speaker, fromFinal: sequence, at: start)
        // A short line after a voice change belongs to the voice matched next, or to no one enrolled.
        if let short = shortVoiceChangeLines[channel], short < sequence {
            shortVoiceChangeLines[channel] = nil
            if let index = index(ofFinal: short) {
                setSpeaker(speaker, fromFinal: short, at: index)
            }
        }
        scheduleTurnExpiry()
    }

    /// Sets the line and the lines that inherit from it, even when its match lands after them.
    private func setSpeaker(_ speaker: String, fromFinal sequence: Int, at start: Int) {
        let channel = recentFinals[start].channel
        setSpeaker(speaker, at: start)
        var next = start + 1
        while next < recentFinals.count, inheritingFinals.contains(sequence + next - start),
              recentFinals[next].channel == channel {
            setSpeaker(speaker, at: next)
            next += 1
        }
    }

    /// For a final too short to match: it is most likely the rest of the sentence before it, so it
    /// shows that line's speaker, now or once that line's match lands. Only when the line before it
    /// is on the same channel.
    func inheritSpeaker(forFinal sequence: Int) {
        guard let index = index(ofFinal: sequence) else { return }
        let channel = recentFinals[index].channel
        // The line before is the previous voice's: this one keeps the voice heard since.
        if voiceChangeLines[channel] == sequence {
            shortVoiceChangeLines[channel] = sequence
            return
        }
        guard index > 0, recentFinals[index - 1].channel == channel else { return }
        let firstKept = finalSequence - (recentFinals.count - 1)
        inheritingFinals = inheritingFinals.filter { $0 >= firstKept }
        inheritingFinals.insert(sequence)
        let previous = recentFinals[index - 1].speaker
        if previous != label(for: recentFinals[index].channel) {
            setSpeaker(previous, at: index)
            scheduleTurnExpiry()
        }
    }

    /// No confident match: the line keeps the speaker of the line before it when that voice is also
    /// its nearest, so a weak slice inside one speaker's turn does not split it under the channel label.
    func resolveUnmatched(forFinal sequence: Int, nearest: String?) {
        awaitingSpeaker.remove(sequence)
        guard let index = index(ofFinal: sequence) else { return }
        let channel = recentFinals[index].channel
        if index > 0, let nearest, recentFinals[index - 1].channel == channel,
           recentFinals[index - 1].speaker == nearest {
            updateSpeaker(nearest, forFinal: sequence)
        } else {
            // Shown under the detector's voice meanwhile; unmatched, it may be someone not enrolled.
            updateSpeaker(label(for: channel), forFinal: sequence)
        }
    }

    /// The detector's voice on `channel`, for the live text; nil when none is pending.
    func voiceHint(for channel: LiveCaptionChannel) -> String? {
        voiceHints[channel]
    }

    /// Another enrolled voice took over `channel`: its live text and next line show it.
    func voiceChanged(to voice: String, channel: LiveCaptionChannel) {
        voiceHints[channel] = voice
        // A pending short line is the previous voice's: the next match is another voice's.
        shortVoiceChangeLines[channel] = nil
    }

    /// True while the speaker match of the line at `index` in `recentFinals` is still running, or that
    /// of the line a short line inherits from.
    func awaitsSpeaker(lineAt index: Int) -> Bool {
        let sequence = finalSequence - (recentFinals.count - 1 - index)
        if awaitingSpeaker.contains(sequence) { return true }
        return index > 0 && inheritingFinals.contains(sequence) && awaitsSpeaker(lineAt: index - 1)
    }

    private func index(ofFinal sequence: Int) -> Int? {
        let distance = finalSequence - sequence
        guard distance >= 0, distance < recentFinals.count else { return nil }
        return recentFinals.count - 1 - distance
    }

    private func setSpeaker(_ speaker: String, at index: Int) {
        let line = recentFinals[index]
        recentFinals[index] = LiveCaptionLine(channel: line.channel, text: line.text, speaker: speaker)
    }

    /// Sequence of the first final in the trailing run of one channel and speaker: the current turn.
    private var currentTurnStart: Int {
        guard let last = recentFinals.last else { return finalSequence + 1 }
        var index = recentFinals.count - 1
        while index > 0, recentFinals[index - 1].channel == last.channel, recentFinals[index - 1].speaker == last.speaker {
            index -= 1
        }
        return finalSequence - (recentFinals.count - 1 - index)
    }

    /// Once a new turn starts, the lines before it leave after `earlierTurnHold`; without this
    /// they stayed until the page turn, above the next speaker's row.
    private func scheduleTurnExpiry() {
        // A short line can follow a still-unresolved match in the same turn.
        let start = currentTurnStart
        guard !awaitingSpeaker.contains(where: { $0 >= start }) else { return }
        let firstKept = finalSequence - (recentFinals.count - 1)
        guard start > firstKept, start > scheduledTurnStart else { return }
        scheduledTurnStart = start
        func schedule(on clock: some Clock<Duration>) {
            let deadline = clock.now.advanced(by: .seconds(Self.earlierTurnHold))
            // Not cancelled by clear(): its boundary then lies before every newer line, so it removes nothing.
            Task { @MainActor [weak self] in
                try? await clock.sleep(until: deadline, tolerance: nil)
                guard !Task.isCancelled, let self else { return }
                // A relabel since may have joined the older lines to the current turn: keep those.
                let boundary = min(start, currentTurnStart)
                let firstKept = finalSequence - (recentFinals.count - 1)
                recentFinals.removeFirst(min(recentFinals.count, max(0, boundary - firstKept)))
            }
        }
        let expiryClock = clock
        schedule(on: expiryClock)
    }

    /// Convenience: speaker defaults to the channel label. Used by tests
    /// and as a fallback path when the live matcher isn't wired in.
    @discardableResult
    func applyFinalized(_ text: String, channel: LiveCaptionChannel, awaitingSpeaker: Bool = false) -> Int {
        applyFinalized(text, channel: channel, speaker: label(for: channel), awaitingSpeaker: awaitingSpeaker)
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
        isDetectingLanguage = false
        hypothesisMic = ""
        hypothesisApp = ""
        recentFinals.removeAll()
        inheritingFinals.removeAll()
        awaitingSpeaker.removeAll()
        voiceHints.removeAll()
        voiceChangeLines.removeAll()
        shortVoiceChangeLines.removeAll()
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
        isDetectingLanguage
            || !hypothesisMic.isEmpty
            || !hypothesisApp.isEmpty
            || !recentFinals.isEmpty
    }
}
