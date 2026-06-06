import AudioTapLib
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "StreamingTranscriber")

/// Live transcription for a single audio channel (mic or app).
///
/// PoC scope: ingests 16 kHz mono Float32 buffers (matches `MicCaptureHandler`
/// post-resample output), feeds them through `FluidVAD` in streaming mode,
/// and calls `engine.transcribeSamples` once per ~400 ms while speaking
/// (partial) and once per detected speech end / 5 s force-flush (final).
///
/// Both mic and app channels are supported. App-channel buffers (typically
/// interleaved 48 kHz stereo from `CATapDescription`) are downmixed and
/// resampled to 16 kHz mono upstream in `LiveTranscriptionController` (via
/// `LiveAudioResampler`) before they reach `ingest`, so this actor always
/// sees the 16 kHz mono format described above.
///
/// Conforms to `LiveCaptionPipeline` — the VAD-driven strategy behind that
/// seam. `ingest(_:)` is the protocol requirement.
actor StreamingTranscriber: LiveCaptionPipeline {
    enum Event {
        case partial(String)
        /// Finalized utterance. `audio` carries the buffered 16 kHz mono
        /// speech samples that drove the transcription so downstream
        /// consumers (e.g. `LiveSpeakerMatcher`) can derive a speaker
        /// embedding from the exact same window without a second VAD pass.
        /// 1–5 seconds of float32 mono = 64–320 KB per event, emitted at
        /// most once per ~5 s — small enough to ship by value.
        case finalized(text: String, audio: [Float])
    }

    typealias EventSink = @Sendable (Event) -> Void
    /// Sample-based transcription closure. Wraps any `TranscribingEngine`
    /// from outside the actor's isolation — typically the caller binds the
    /// engine in a `@Sendable` closure on the main actor.
    typealias TranscribeFunction = @Sendable ([Float]) async throws -> String

    private let transcribe: TranscribeFunction
    private let channelLabel: String
    private let vad: FluidVAD
    private var vadState: FluidVAD.StreamState?
    private var inputAccumulator: [Float] = []
    private var speechSamples: [Float] = []
    private var isSpeaking = false
    private var lastPartialAt: Date = .distantPast
    private let onEvent: EventSink
    /// True while a `drainChunks()` pass owns the input accumulator. The actor
    /// suspends at the VAD and transcribe awaits, so a second caller (another
    /// `ingest` Task or `flush`) can interleave; without this guard two drain
    /// loops would fork the VAD stream state and process chunks out of order.
    private var isDrainingInput = false

    /// Silero v6 chunk size at 16 kHz — what FluidVAD expects per call.
    private static let chunkSize = 4096
    private static let partialIntervalSeconds: TimeInterval = 0.4
    /// 5 seconds at 16 kHz — force a final when speech keeps going without an end event.
    private static let forceFlushSamples = 16000 * 5
    /// Below 1 second of accumulated speech, drop instead of transcribing (noise).
    private static let minFinalSamples = 16000

    init(
        channelLabel: String,
        vad: FluidVAD,
        transcribe: @escaping TranscribeFunction,
        onEvent: @escaping EventSink,
    ) {
        self.channelLabel = channelLabel
        self.vad = vad
        self.transcribe = transcribe
        self.onEvent = onEvent
    }

    /// Feed a captured buffer into the streaming pipeline. Buffers that don't
    /// match the expected 16 kHz mono shape are dropped silently. Both mic and
    /// app channels are normalized to that shape upstream (mic via
    /// `MicCaptureHandler`, app via `LiveAudioResampler` in
    /// `LiveTranscriptionController`) before reaching here.
    func ingest(_ buffer: LiveAudioBuffer) async {
        guard buffer.channelCount == 1, buffer.sampleRate == 16000 else { return }
        inputAccumulator.append(contentsOf: buffer.samples)
        await drainChunks()
    }

    /// Recording stopped — commit any pending speech as a final so the last
    /// utterance isn't dropped when the recorder stops mid-speech (no VAD
    /// `speechEnd` event ever arrives for the tail). `commitFinal()` keeps the
    /// ≥1 s `minFinalSamples` guard, so sub-second pending speech is still
    /// dropped as noise. Reset `isSpeaking` afterwards so the actor returns to
    /// a clean idle state (the controller recreates pipelines per recording, so
    /// this is belt-and-suspenders against any reuse).
    func flush() async {
        // Ingestion may still be mid-drain (the actor suspends at the VAD and
        // partial-transcribe awaits) — wait for the active pass to finish and
        // process any input that accumulated meanwhile, so audio the recorder
        // already delivered before the stop isn't dropped by stop-timing.
        while isDrainingInput {
            await Task.yield()
        }
        if !inputAccumulator.isEmpty { await drainChunks() }
        await commitFinal()
        isSpeaking = false
    }

    private func drainChunks() async {
        // Single-pass guard: the active drain re-checks the accumulator every
        // iteration, so anything appended while it runs is consumed by it.
        if isDrainingInput { return }
        isDrainingInput = true
        defer { isDrainingInput = false }
        if vadState == nil {
            do {
                vadState = try await vad.makeStreamState()
            } catch {
                logger.error(
                    "[\(self.channelLabel, privacy: .public)] vad init failed: \(error)",
                )
                return
            }
        }

        while inputAccumulator.count >= Self.chunkSize {
            let chunk = Array(inputAccumulator.prefix(Self.chunkSize))
            inputAccumulator.removeFirst(Self.chunkSize)
            guard let state = vadState else { return }
            do {
                let result = try await vad.processStreamingChunk(chunk, state: state)
                vadState = result.state
                await handleEvent(result.event, chunk: chunk)
            } catch {
                logger.warning(
                    "[\(self.channelLabel, privacy: .public)] vad chunk error: \(error)",
                )
            }
        }
    }

    private func handleEvent(_ event: FluidVAD.StreamEvent?, chunk: [Float]) async {
        switch event?.kind {
        case .speechStart:
            isSpeaking = true
            speechSamples.append(contentsOf: chunk)
            lastPartialAt = .distantPast

        case .speechEnd:
            isSpeaking = false
            await commitFinal()

        case .none:
            if isSpeaking {
                speechSamples.append(contentsOf: chunk)
                await maybeEmitPartial()
                if speechSamples.count >= Self.forceFlushSamples {
                    await commitFinal()
                }
            }
        }
    }

    private func maybeEmitPartial() async {
        let now = Date()
        guard now.timeIntervalSince(lastPartialAt) >= Self.partialIntervalSeconds else { return }
        guard !speechSamples.isEmpty else { return }
        lastPartialAt = now
        let snapshot = speechSamples
        do {
            let text = try await transcribe(snapshot)
            if !text.isEmpty {
                onEvent(.partial(text))
            }
        } catch {
            logger.warning(
                "[\(self.channelLabel, privacy: .public)] partial transcribe error: \(error)",
            )
        }
    }

    private func commitFinal() async {
        guard speechSamples.count >= Self.minFinalSamples else {
            speechSamples.removeAll(keepingCapacity: true)
            return
        }
        // Transfer ownership of the speech buffer to `buffer` by replacing
        // `speechSamples` with a fresh empty array, NOT by mutating it
        // via `removeAll(keepingCapacity:)`. Mutating it would trigger a
        // CoW clone of the 64–320 KB buffer (because `buffer` still holds
        // a strong reference at the mutation point); reassignment leaves
        // the original storage uniquely owned by `buffer` and drops our
        // reference for free. The downside is losing the capacity hint for
        // the next utterance — accepted because finals are emitted at most
        // once per second and the realloc dominates neither cost.
        let buffer = speechSamples
        speechSamples = []
        do {
            let text = try await transcribe(buffer)
            if !text.isEmpty {
                onEvent(.finalized(text: text, audio: buffer))
            }
        } catch {
            logger.warning(
                "[\(self.channelLabel, privacy: .public)] final transcribe error: \(error)",
            )
        }
    }
}
