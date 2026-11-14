import AudioTapLib
@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "EouStreamingCaptionSession")

/// Narrow seam over FluidAudio's `StreamingEouAsrManager`: the library's
/// generic `StreamingAsrManager` protocol lacks the EOU callback and
/// timestamp surface this session needs, so we declare exactly the methods
/// we consume and conform the concrete actor via extension. Also the mock
/// seam for unit tests.
protocol EouStreamingAsrManaging: Actor {
    func loadModels() async throws
    func appendAudio(_ buffer: AVAudioPCMBuffer) throws
    func processBufferedAudio() async throws
    func finish() async throws -> String
    func reset() async
    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void)
    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void)
    func getEouTimestampsMs() -> [Int]
}

extension StreamingEouAsrManager: EouStreamingAsrManaging {}

/// One caption event collected from a manager callback, awaiting drain on the
/// session actor. `kind` distinguishes a partial (ghost text) from a confirmed
/// end-of-utterance.
private struct CapturedCallback {
    enum Kind { case partial, eou }
    let kind: Kind
    let text: String
}

/// Lock-protected FIFO the manager's `@Sendable` callbacks append into. The
/// callbacks fire synchronously on the manager's executor during
/// `processBufferedAudio()`, off the session actor, so they cannot touch the
/// actor directly — they push records here instead, and the session drains them
/// (in order) once `processBufferedAudio()` returns. `final class` + an unfair
/// lock keeps it `Sendable` without `@unchecked Sendable` on the session.
private final class CallbackCollector: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [CapturedCallback]())

    func append(_ record: CapturedCallback) {
        storage.withLock { $0.append(record) }
    }

    /// Returns everything collected so far and clears the buffer.
    func drain() -> [CapturedCallback] {
        storage.withLock { records in
            let snapshot = records
            records.removeAll(keepingCapacity: true)
            return snapshot
        }
    }
}

/// Low-latency English live-captions strategy: wraps FluidAudio's cache-aware
/// streaming Parakeet EOU manager (built-in end-of-utterance detection) behind
/// the `LiveCaptionPipeline` seam, as an alternative to the VAD + re-transcribe
/// `StreamingTranscriber`.
///
/// **Invariant:** every sample that enters the manager (via `appendAudio`) also
/// enters `ring` first, in the same order. That equivalence is what keeps the
/// manager's millisecond timestamps (`getEouTimestampsMs`, absolute since stream
/// start) valid as coordinates into `ring` — the API exposes only utterance
/// *text* and time ranges, never the audio, so we slice the raw samples
/// ourselves for downstream live speaker matching.
///
/// **FluidAudio facts baked into the flow (verified against the real models):**
/// - `process()` always returns `""`; transcript arrives only via callbacks /
///   `finish()`. We therefore never call `process()`.
/// - Callbacks (`setPartialCallback` / `setEouCallback`) fire SYNCHRONOUSLY on
///   the manager's executor during `processBufferedAudio()`, so by the time our
///   `await processBufferedAudio()` returns, every callback for those chunks has
///   already pushed into the collector — draining it once afterwards is complete
///   and ordered. We deliberately avoid unstructured `Task` hops, which would be
///   unordered.
/// - The manager's accumulated transcript keeps GROWING across utterances
///   (cleared only by `reset()`), and partials are strictly prefix-monotonic —
///   hence prefix-stripping each callback text against the last finalized prefix.
/// - `finish()` is DESTRUCTIVE (clears the token / EOU accumulators) and its
///   RETURN VALUE is the full accumulated transcript: the right source for the
///   trailing final at flush. We never read post-hoc getters after `finish()`.
/// - `reset()` is cheap (clears decoding + buffer state, models stay loaded) and
///   restarts the manager's millisecond timeline at 0 — so flush resets all of
///   our session state too.
actor EouStreamingCaptionSession: LiveCaptionPipeline {
    private let asr: any EouStreamingAsrManaging
    private let channelLabel: String
    private let onEvent: StreamingTranscriber.EventSink

    /// Parallel copy of every sample fed to the manager, sliced per utterance.
    private var ring = UtteranceRingBuffer()
    /// Start of unassigned speaker audio, advanced by real EOU or text-only finals.
    private var audioCursorMs = 0
    /// Transcript prefix already finalized — stripped from later callback texts
    /// because the manager's accumulated transcript grows across utterances.
    private var lastFinalizedPrefix = ""
    private var runningTranscript = ""
    private var lastEmittedPartial = ""
    private var splitter: StreamingCaptionSplitter
    /// Total samples ingested so far (16 kHz). Doubles as the absolute-ms cursor
    /// (`/ 16`) for the flush tail slice and an EOU-timestamp fallback. The
    /// integer `/ 16` truncates at most 15 samples (≤0.9 ms) off the tail end —
    /// intentional and harmless for caption audio.
    private var ingestedSamples = 0
    /// Whether the manager callbacks have been installed (init can't await into
    /// another actor, so we install lazily on first ingest).
    private var callbacksInstalled = false

    private let collector = CallbackCollector()

    /// 16 kHz: 1 ms == 16 samples (fixed; the whole live path is 16 kHz mono).
    private static let samplesPerMs = 16

    init(
        asr: any EouStreamingAsrManaging,
        channelLabel: String,
        splitter: StreamingCaptionSplitter = StreamingCaptionSplitter(),
        onEvent: @escaping StreamingTranscriber.EventSink,
    ) {
        self.asr = asr
        self.channelLabel = channelLabel
        self.splitter = splitter
        self.onEvent = onEvent
    }

    /// Load the streaming models. Rethrows so the caller decides whether to fall
    /// back to another strategy when the EOU models are unavailable.
    func prepare() async throws {
        try await asr.loadModels()
    }

    func reset() async {
        await asr.reset()
        _ = collector.drain()
        resetSessionState()
        onEvent(.partial(""))
    }

    /// Feed a captured buffer into the streaming pipeline. Buffers that don't
    /// match the expected 16 kHz mono shape are dropped silently — upstream
    /// (`LiveTranscriptionController` / `MicCaptureHandler`) normalizes both
    /// channels to that shape, same guard as `StreamingTranscriber.ingest`.
    ///
    /// Calls are serialized by the driver (one ingest at a time, in capture
    /// order — see the `LiveCaptionPipeline` contract), which is what keeps
    /// ring order == manager feed order and the EOU-ms → ring-slice mapping
    /// valid without any re-entrancy machinery here.
    func ingest(_ buffer: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) async {
        guard buffer.channelCount == 1, buffer.sampleRate == 16000 else { return }
        await installCallbacksIfNeeded()
        guard let pcm = Self.makeBuffer(buffer.samples) else { return }

        do {
            // Advance the ring + counter only AFTER the manager accepts the
            // samples, so a thrown appendAudio can't leave the ring ahead of
            // the manager and permanently skew the ms timeline. A
            // processBufferedAudio failure after a successful append is
            // benign — the manager already holds the samples.
            try await asr.appendAudio(pcm)
            ring.append(buffer.samples)
            ingestedSamples += buffer.samples.count
            try await asr.processBufferedAudio()
        } catch {
            // Never throw out of ingest — log and move on. Transcript text is
            // never logged; only the (public) channel label and the error.
            logger.warning("[\(self.channelLabel, privacy: .public)] ingest error: \(error.localizedDescription, privacy: .public)")
            return
        }

        await drainCollector()
        // Callbacks fire only for new tokens, so silence must also advance the audio clock.
        emit(splitter.update(runningTranscript, audioTime: audioTime), throughMs: ingestedSamples / Self.samplesPerMs)
    }

    /// Recording stopped — commit the trailing utterance via `finish()`
    /// (whose return value carries the transcript), then reset all state so a
    /// subsequent recording starts clean. The driver retires the channel feed
    /// before flushing, so every buffer delivered before the stop has already
    /// been ingested when this runs. Idempotent: a second flush (or a flush
    /// before any ingest) emits nothing and never calls `finish()` again,
    /// because the reset zeroes `ingestedSamples`.
    func flush() async {
        guard ingestedSamples > 0 else { return }

        do {
            let transcript = try await asr.finish()
            emit(
                splitter.update(strippingPrefix(from: transcript), audioTime: audioTime, finalize: true),
                throughMs: ingestedSamples / Self.samplesPerMs,
            )
        } catch {
            // Never throw out of flush — log and still reset below so the next
            // recording starts clean. Transcript text is never logged.
            logger.warning("[\(self.channelLabel, privacy: .public)] flush finish error: \(error.localizedDescription, privacy: .public)")
        }

        await asr.reset()
        _ = collector.drain()
        resetSessionState()
    }

    private func resetSessionState() {
        ring = UtteranceRingBuffer()
        audioCursorMs = 0
        lastFinalizedPrefix = ""
        runningTranscript = ""
        lastEmittedPartial = ""
        splitter.reset()
        ingestedSamples = 0
    }

    // MARK: - Callbacks

    /// Installs both manager callbacks on first ingest (init can't await into
    /// another actor). Must be awaited BEFORE the first `processBufferedAudio()`
    /// so the very first chunk's callbacks have somewhere to land.
    private func installCallbacksIfNeeded() async {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true
        let collector = collector
        await asr.setPartialCallback { collector.append(CapturedCallback(kind: .partial, text: $0)) }
        await asr.setEouCallback { collector.append(CapturedCallback(kind: .eou, text: $0)) }
    }

    /// Drain and handle every callback the just-completed `processBufferedAudio()`
    /// pass produced, in order, on the session actor.
    private func drainCollector() async {
        for record in collector.drain() {
            switch record.kind {
            case .partial:
                handlePartial(record.text)

            case .eou:
                await handleEou(record.text)
            }
        }
    }

    private var audioTime: TimeInterval {
        Double(ingestedSamples) / 16000
    }

    private func handlePartial(_ text: String) {
        runningTranscript = strippingPrefix(from: text)
        emit(splitter.update(runningTranscript, audioTime: audioTime), throughMs: ingestedSamples / Self.samplesPerMs)
    }

    private func handleEou(_ text: String) async {
        let eouMs = await asr.getEouTimestampsMs().last ?? (ingestedSamples / Self.samplesPerMs)
        emit(
            splitter.update(strippingPrefix(from: text), audioTime: audioTime, finalize: true),
            throughMs: eouMs,
        )
        // EOU text is still cumulative in FluidAudio; rebase the text-only offset here.
        lastFinalizedPrefix = text
        audioCursorMs = max(audioCursorMs, eouMs)
        runningTranscript = ""
        lastEmittedPartial = ""
        splitter.reset()
    }

    private func emit(_ update: StreamingCaptionSplitter.Update, throughMs: Int) {
        for text in update.finals {
            // Text-only boundaries lack word timestamps. Use unassigned audio once;
            // additional lines in the same callback have no separate speaker sample.
            let audio = ring.extract(fromMs: audioCursorMs, toMs: throughMs)
            audioCursorMs = max(audioCursorMs, throughMs)
            onEvent(.finalized(text: text, audio: audio))
            lastEmittedPartial = ""
        }
        if !update.hypothesis.isEmpty, update.hypothesis != lastEmittedPartial {
            lastEmittedPartial = update.hypothesis
            onEvent(.partial(update.hypothesis))
        }
    }

    /// Strips `lastFinalizedPrefix` from the front of `text` (the manager's
    /// transcript accumulates across utterances) and trims surrounding whitespace.
    private func strippingPrefix(from text: String) -> String {
        let stripped = text.hasPrefix(lastFinalizedPrefix)
            ? String(text.dropFirst(lastFinalizedPrefix.count))
            : text
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a fresh 16 kHz mono Float32 `AVAudioPCMBuffer` from `samples`. A
    /// new buffer per call satisfies Swift 6 region-based `sending`: it is never
    /// touched again after being passed into the manager actor. `static` so it
    /// captures no session state. Returns `nil` for empty input or the
    /// (in practice unreachable) allocation failure of the constant format.
    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16000,
                  channels: 1,
                  interleaved: false,
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channel[0].update(from: base, count: samples.count)
            }
        }
        return buffer
    }
}
