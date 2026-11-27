import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

/// The event sink every caption pipeline delivers its partials and finals through.
extension LiveTranscriptionController {
    /// 1 s at 16 kHz. The embedding extractor loops shorter audio up to its
    /// window, so a short slice could put a wrong name on the line; such a line
    /// takes the speaker of the line before it instead (`inheritSpeaker`).
    static let minSpeakerMatchSamples = 16000

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
        return { [weak self] event in
            Task { @MainActor in
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
                    guard matchable else {
                        self.captions.inheritSpeaker(forFinal: sequence)
                        return
                    }
                    let match = await self.speakerMatcher.match(audio: audio)
                    if let name = match.name {
                        self.captions.updateSpeaker(name, forFinal: sequence)
                    } else {
                        self.captions.resolveUnmatched(forFinal: sequence, nearest: match.nearest)
                    }

                case let .voiceChanged(voice):
                    self.captions.voiceChanged(to: voice, channel: channel)
                }
            }
        }
    }
}
