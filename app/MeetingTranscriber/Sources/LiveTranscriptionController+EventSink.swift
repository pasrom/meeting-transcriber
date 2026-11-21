import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

/// The event sink every caption pipeline delivers its partials and finals through.
extension LiveTranscriptionController {
    /// 1 s at 16 kHz. The embedding extractor loops shorter audio up to its
    /// window, so a short slice could put a wrong name on the line; such a line
    /// takes the speaker of the line before it instead (`inheritSpeaker`).
    static let minSpeakerMatchSamples = 16000

    /// Names the speaker of final `sequence`: inherited when its audio is too short to
    /// match, else from a live match, which also goes to the transcript file the final went to.
    private func resolveSpeaker(forFinal sequence: Int, audio: [Float], matchable: Bool, transcript: LiveTranscriptFile?) async {
        guard matchable else {
            captions.inheritSpeaker(forFinal: sequence)
            return
        }
        let match = await speakerMatcher.match(audio: audio)
        if let name = match.name {
            captions.updateSpeaker(name, forFinal: sequence)
            transcript?.appendSpeaker(sequence: sequence, speaker: name)
        } else {
            captions.resolveUnmatched(forFinal: sequence, nearest: match.nearest)
        }
    }

    /// Detaches the current transcript file and ends it once its events still in flight
    /// landed, at most `transcriptEndWait` later. Not awaited: a slow speaker match must not
    /// hold the stop-time flush, which the next recording's start awaits. A quit waits for
    /// it through `transcriptEnds`.
    func endTranscriptFile() {
        guard let file = detachTranscriptFile() else { return }
        transcriptEnds.end(file, waitingUpTo: transcriptEndWait)
    }

    /// Ends the current transcript file at once, dropping its events in flight; for the
    /// last moment before exit.
    func endTranscriptFileNow() {
        detachTranscriptFile()?.appendEnd()
    }

    /// Removes the current transcript file, for a recording that never started.
    func discardTranscriptFile() {
        detachTranscriptFile()?.discard()
    }

    private func detachTranscriptFile() -> LiveTranscriptFile? {
        transcriptFileSlot.withLock { slot in
            defer { slot = nil }
            return slot
        }
    }

    /// Shared partial/final sink for both pipeline strategies: applies the
    /// partial as ghost text and each final immediately, then resolves its speaker
    /// without delaying newer text. Caption text is gated +
    /// `.private` so spoken content never lands in the unified log by default.
    ///
    /// Log prefix uses the raw channel id, not the user-visible speaker label:
    /// the label is resolved per final (so it may differ per utterance) and the
    /// log args here are `.public` — a matched name would leak enrolled speaker
    /// identities into the unified log.
    func makeEventSink(
        channel: LiveCaptionChannel,
        logChannel: String,
    ) -> StreamingTranscriber.EventSink {
        let generation = generation
        let transcriptFileSlot = transcriptFileSlot
        return { [weak self] event in
            // Counted inside the lock: a file detached for its end either sees this
            // event counted or is no longer there to be read.
            let transcript = transcriptFileSlot.withLock { slot in
                slot?.eventsInFlight.enter()
                return slot
            }
            Task { @MainActor in
                defer { transcript?.eventsInFlight.leave() }
                guard let self, generation == self.generation else { return }
                switch event {
                case let .partial(text):
                    if self.verboseDiagnostics() {
                        // `.private` on `text` masks the spoken content in
                        // `log show` / Console.app unless the system is in
                        // Private Data Capture mode. Defence in depth on top
                        // of the gate.
                        logger.info("[\(logChannel, privacy: .public)] partial: \(text, privacy: .private)")
                    }
                    self.captions.applyPartial(text, channel: channel)

                case let .finalized(text, audio):
                    if self.verboseDiagnostics() {
                        logger.info("[\(logChannel, privacy: .public)] final: \(text, privacy: .private)")
                    }
                    let matchable = audio.count >= Self.minSpeakerMatchSamples
                    let sequence = self.captions.applyFinalized(text, channel: channel, awaitingSpeaker: matchable)
                    transcript?.appendFinal(sequence: sequence, channel: channel, speaker: self.captions.label(for: channel), text: text)
                    await self.resolveSpeaker(forFinal: sequence, audio: audio, matchable: matchable, transcript: transcript)

                case let .voiceChanged(voice):
                    self.captions.voiceChanged(to: voice, channel: channel)
                }
            }
        }
    }
}
