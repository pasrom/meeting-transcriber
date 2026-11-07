import AudioTapLib
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "NemotronCaptions")

// MARK: - Seams

/// The slice of `StreamingNemotronMultilingualAsrManager` the caption session
/// drives, behind a protocol so the session is unit-testable without loading
/// the real CoreML models. `latestTranscript()` returns the manager's full
/// settled running transcript since the previous call (nil if no new partial fired).
/// FluidAudio's callback only extends prior text, including with blank rescue;
/// the implementation drains a callback FIFO, so the session reads it once
/// per chunk and caches the value for the partial + final reads.
protocol NemotronStreamingAsrManaging: Actor {
    /// Bind to the shared models + language (real impl: `loadFromShared` + `setLanguage`).
    func prepare() async throws
    /// Feed one audio chunk (16 kHz mono Float32).
    func process(_ samples: [Float]) async throws
    /// Latest full running transcript since the previous call, or nil if none new.
    func latestTranscript() -> String?
    /// Flush remaining buffered audio and return the complete transcript.
    func finish() async throws -> String
    /// Full reset (encoder caches + accumulated transcript).
    func reset() async
}

/// Per-channel streaming utterance-boundary detector. Wraps `FluidVAD`'s
/// state-threading so the session (and its tests) see only `speechStart` /
/// `speechEnd`, never the opaque `StreamState`.
protocol UtteranceBoundaryDetecting: Actor {
    /// Feed one 4096-sample chunk; returns a boundary kind if one occurred.
    func boundary(in chunk: [Float]) async throws -> FluidVAD.StreamEvent.Kind?
    /// Drop the streaming state so the next chunk starts a fresh stream.
    func reset() async
}

/// VAD attempts per chunk before a live-caption session gives up on that chunk.
let vadAttemptsPerChunk = 3

extension UtteranceBoundaryDetecting {
    func boundaryWithRetries(in chunk: [Float]) async throws -> FluidVAD.StreamEvent.Kind? {
        var failures = 0
        while true {
            do {
                return try await boundary(in: chunk)
            } catch {
                failures += 1
                if failures >= vadAttemptsPerChunk { throw error }
            }
        }
    }
}

// MARK: - Session

/// Live captions for one channel via FluidAudio's cache-aware
/// `StreamingNemotronMultilingualAsrManager` (language set per session), behind
/// the `LiveCaptionPipeline` seam. Audio is fed continuously to the manager (it
/// keeps cross-utterance acoustic context); a `FluidVAD`-backed boundary
/// detector decides when an utterance ends, at which point `finish()`
/// force-decodes the tail and returns the complete utterance text, emitted as a
/// final paired with the utterance's speech audio (so the controller's event
/// sink can derive a speaker embedding from the same window, as for the
/// re-transcribe path).
///
/// Calls are serialized by the driver (the `LiveCaptionPipeline` contract), so
/// `ingest`/`flush` never interleave and need no re-entrancy guards.
actor NemotronStreamingCaptionSession: LiveCaptionPipeline {
    private let manager: any NemotronStreamingAsrManaging
    private let detector: any UtteranceBoundaryDetecting
    private let channelLabel: String
    private let onEvent: StreamingTranscriber.EventSink

    private var inputAccumulator: [Float] = []
    private var speechSamples: [Float] = []
    private var emittedAudioSamples = 0
    // Nemotron decodes every ~2.24 s; unchanged text is not a pause signal here.
    private var splitter = StreamingCaptionSplitter(pauseSeconds: .infinity)
    private var isSpeaking = false
    /// Cached in-progress partial for the current utterance. The manager's
    /// `latestTranscript()` drains its callback FIFO (nil when no new partial
    /// fired this chunk), so it's read once per chunk and cached for the partial
    /// emit. Reset to empty after each `finish()`.
    private var runningTranscript = ""
    /// Last partial actually emitted, to skip re-emitting identical text on the
    /// chunks where no new partial fired (the manager only decodes every ~2.24 s).
    private var lastEmittedPartial = ""

    /// Silero v6 chunk size at 16 kHz — what `FluidVAD` expects per call.
    private static let chunkSize = 4096
    /// 1 s at 16 kHz — utterances shorter than this are dropped as noise.
    private static let minFinalSamples = 16000
    /// 5 s at 16 kHz — force a final when speech keeps going without an end event.
    private static let forceFlushSamples = 16000 * 5

    init(
        manager: any NemotronStreamingAsrManaging,
        detector: any UtteranceBoundaryDetecting,
        channelLabel: String,
        onEvent: @escaping StreamingTranscriber.EventSink,
    ) {
        self.manager = manager
        self.detector = detector
        self.channelLabel = channelLabel
        self.onEvent = onEvent
    }

    /// Load the models for this channel. Rethrows so the controller can fall
    /// back when the load fails.
    func prepare() async throws {
        try await manager.prepare()
    }

    func reset() async {
        await resetStream()
        onEvent(.partial(""))
    }

    func ingest(_ buffer: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) async {
        guard buffer.channelCount == 1, buffer.sampleRate == 16000 else { return }
        inputAccumulator.append(contentsOf: buffer.samples)
        await drainChunks()
    }

    /// Recording stopped — commit any pending speech as a final (the recorder
    /// can stop mid-utterance, so no VAD `speechEnd` ever arrives for the tail),
    /// then reset both collaborators to a clean idle state.
    func flush() async {
        if !inputAccumulator.isEmpty { await drainChunks() }
        if !speechSamples.isEmpty { await commitFinal() }
        await resetStream()
    }

    private func resetStream() async {
        await detector.reset()
        await manager.reset()
        _ = await manager.latestTranscript()
        isSpeaking = false
        speechSamples = []
        resetUtteranceState()
        inputAccumulator = []
    }

    private func drainChunks() async {
        while inputAccumulator.count >= Self.chunkSize {
            let chunk = Array(inputAccumulator.prefix(Self.chunkSize))
            inputAccumulator.removeFirst(Self.chunkSize)
            do {
                try await manager.process(chunk)
                if let latest = await manager.latestTranscript() { runningTranscript = latest }
            } catch {
                // Log but keep driving VAD: dropping the chunk's boundary check on a
                // transient ASR error could lose a `speechEnd` and desync segmentation.
                logger.warning("[\(self.channelLabel, privacy: .public)] process error: \(error.localizedDescription, privacy: .public)")
            }
            let event: FluidVAD.StreamEvent.Kind?
            do {
                event = try await detector.boundaryWithRetries(in: chunk)
            } catch {
                // The ASR stream already consumed the chunk; skipping it there would splice audio.
                logger.warning(
                    "[\(self.channelLabel, privacy: .public)] vad error after \(vadAttemptsPerChunk) attempts: \(error.localizedDescription, privacy: .public)",
                )
                event = nil
            }
            await handleEvent(event, chunk: chunk)
        }
    }

    private func handleEvent(_ kind: FluidVAD.StreamEvent.Kind?, chunk: [Float]) async {
        switch kind {
        case .speechStart:
            isSpeaking = true
            speechSamples = chunk

        case .speechEnd:
            isSpeaking = false
            await commitFinal()

        case .none:
            guard isSpeaking else { return }
            speechSamples.append(contentsOf: chunk)
            emitPartial()
            if speechSamples.count >= Self.forceFlushSamples { await commitFinal() }
        }
    }

    private func emitPartial() {
        let update = splitter.update(runningTranscript, audioTime: speechSeconds)
        emitFinals(update.finals)
        guard !update.hypothesis.isEmpty, update.hypothesis != lastEmittedPartial else { return }
        lastEmittedPartial = update.hypothesis
        onEvent(.partial(update.hypothesis))
    }

    /// Finalize the current utterance: `finish()` force-decodes the buffered tail
    /// and returns the complete transcript, clearing the manager's token
    /// accumulation while keeping encoder state. Text already committed at a
    /// word boundary is stripped before resetting the splitter. `finish()` runs
    /// even for sub-second noise, so its text cannot leak into the next final.
    /// The 1 s gate uses the whole utterance, not just a split line's audio.
    private func commitFinal() async {
        defer {
            speechSamples = []
            resetUtteranceState()
        }
        let transcript: String
        do {
            transcript = try await manager.finish()
        } catch {
            logger.warning("[\(self.channelLabel, privacy: .public)] finish error: \(error.localizedDescription, privacy: .public)")
            return
        }
        // `finish()` decodes the padded tail and can push one last partial into
        // the manager's FIFO; drain + discard it so it can't surface as the next
        // utterance's first partial.
        _ = await manager.latestTranscript()
        guard speechSamples.count >= Self.minFinalSamples || emittedAudioSamples > 0 else { return }
        emitFinals(splitter.update(transcript, audioTime: speechSeconds, finalize: true).finals)
    }

    private func emitFinals(_ texts: [String]) {
        for text in texts {
            // Text boundaries have no word timestamps; consume the available
            // acoustic slice once, rather than reusing it for later lines.
            let audio = Array(speechSamples.dropFirst(emittedAudioSamples))
            emittedAudioSamples = speechSamples.count
            onEvent(.finalized(text: text, audio: audio))
            // The sink clears the shown hypothesis on a final; let the remainder show again.
            lastEmittedPartial = ""
        }
    }

    private var speechSeconds: TimeInterval {
        Double(speechSamples.count) / 16000
    }

    private func resetUtteranceState() {
        splitter.reset()
        emittedAudioSamples = 0
        runningTranscript = ""
        lastEmittedPartial = ""
    }
}
