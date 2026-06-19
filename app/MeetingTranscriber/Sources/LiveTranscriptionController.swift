import AudioTapLib
import FluidAudio
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

/// Wires the per-channel caption pipelines to both audio sinks of a
/// `DualSourceRecorder`. Logs partial/final captions via os_log on subsystem
/// `com.meetingtranscriber.app`, category `LiveTranscription`, and feeds them
/// into the observable `LiveCaptionsState` that backs the caption-bar overlay.
///
/// Scope:
///   - mic + app channels supported. Buffers normally arrive 16 kHz mono
///     from capture-time resampling (mic via `MicCaptureHandler`, app via
///     `AppAudioCapture`'s `StreamingMonoResampler`); the app feed still runs
///     `LiveAudioResampler` for the resampler-nil fallback path, where raw
///     device-rate buffers come through (16 kHz mono passes through unchanged).
///   - one engine instance shared by both channels (Parakeet today —
///     other engines fall back to `TranscriptionError.streamingNotSupported`).
///
/// Dataflow: each channel is a bounded `AsyncStream<LiveAudioBuffer>` feed.
/// The sink closure yields into the stream synchronously on the audio
/// callback thread; a single detached consumer task per channel ingests into
/// that channel's `LiveCaptionPipeline`. Ordering (single consumer → FIFO)
/// and backpressure (bounded buffer, newest win) are properties of the
/// channel — pipelines never see interleaved `ingest` calls.
///
/// Lifecycle:
///   1. `prepare()` warms the engine + VAD model, builds the pipelines, and
///      arms the feeds.
///   2. Caller installs `micSink` and `appSink` on the recorder before
///      `recorder.start(...)`.
///   3. `flush()` retires the feeds (draining everything already delivered)
///      and flushes the pipelines; `prepareForNextRecording()` re-arms fresh
///      feeds between recordings (keeps models loaded — re-creating the
///      streaming actors + feeds is cheap).
@MainActor
final class LiveTranscriptionController {
    /// Builds the `EouStreamingAsrManaging` backend for one channel's English
    /// streaming session. Injectable so tests can substitute a mock manager (or
    /// a failing one) without loading the real Parakeet EOU CoreML models. The
    /// production default constructs `StreamingEouAsrManager(chunkSize: .ms320)`
    /// — built ONLY when the English-streaming path is actually taken, so the
    /// default re-transcribe path never pays the model-instance memory.
    typealias EouSessionFactory = @MainActor () -> any EouStreamingAsrManaging

    /// Active engine for the VAD + re-transcribe path. Optional because the
    /// English streaming path is engine-independent: when `englishStreaming` is
    /// on with a non-streaming active engine there is no streaming engine to
    /// hold, and captions still run via the EOU sessions.
    private let engine: (any StreamingTranscribingEngine)?
    private let vad: FluidVAD
    private let captions: LiveCaptionsState
    private let speakerMatcher: any LiveSpeakerMatching
    /// Opt-in to the low-latency English streaming session. When true,
    /// `prepare()` tries to build EOU sessions for both channels; on model-load
    /// failure it degrades to the re-transcribe path if the engine supports it,
    /// or to no captions otherwise.
    private let englishStreaming: Bool
    private let eouSessionFactory: EouSessionFactory
    /// Gate for caption-text logging. Caption strings are spoken user content
    /// — privacy-sensitive — so even with `privacy: .private` on the log
    /// arguments we don't emit by default. Same `() -> Bool` closure pattern
    /// `AppState` already uses for the diarizer + speaker matcher. Tests
    /// construct the controller without a closure (defaults to off).
    ///
    /// Kept on the `@MainActor`-isolated controller (not as a Sendable closure
    /// passed into the transcriber's `@Sendable onEvent`) because `AppSettings`
    /// itself is not `Sendable`. Callers read it via `self.verboseDiagnostics()`
    /// from inside the `Task { @MainActor in ... }` hop in `onEvent`, so the
    /// closure never crosses an isolation boundary.
    private let verboseDiagnostics: () -> Bool
    private var micPipeline: (any LiveCaptionPipeline)?
    private var appPipeline: (any LiveCaptionPipeline)?

    /// One bounded feed per channel (see `CaptionChannelFeed`). The feeds
    /// are (re)armed per recording via `bindFeeds()` and retired by
    /// `flush()`/`retireFeeds()`.
    private let micFeed = CaptionChannelFeed()
    private let appFeed = CaptionChannelFeed()
    /// True once `prepare()` resolved the active strategy to the EOU sessions.
    /// `prepareForNextRecording()` keeps those sessions (already flushed clean at
    /// stop, reloading their models would be wasteful) and only rebuilds the
    /// cheap re-transcribe actors.
    private var usingEnglishStreaming = false
    /// True once `prepare()` has finished resolving + building the pipelines.
    /// Distinguishes "EOU opted-in but `prepare()` hasn't run yet" (pipelines
    /// nil → let `prepare()` own construction) from "EOU opted-in but load failed
    /// and we fell back to re-transcribe" (resolved → refresh those actors). The
    /// two states both have `usingEnglishStreaming == false`; this flag tells
    /// them apart so a reset-before-prepare ordering doesn't pre-empt the EOU path.
    private var strategyResolved = false
    /// The most recent stop-time flush, kept so the NEXT recording's reset can
    /// await it before reusing a kept EOU session. `flush()` is dispatched
    /// fire-and-forget from `WatchingController`, and a slow `asr.finish()` can
    /// otherwise interleave with the next recording's ingests on the same actor —
    /// emitting the old tail as the new recording's caption or zeroing its ring.
    private var pendingFlush: Task<Void, Never>?

    /// Mic-channel live sink. Hand this to `DualSourceRecorder.micLiveSink`
    /// before `recorder.start(...)`. Buffers arrive on the AVAudioEngine tap
    /// thread; the closure yields into the channel's bounded feed and returns
    /// immediately — no task spawn, no actor hop on the audio thread.
    var micSink: LiveAudioSink {
        micFeed.sink
    }

    /// App-channel live sink. Hand this to `DualSourceRecorder.appLiveSink`
    /// before `recorder.start(...)`. Buffers arrive on the CATap IOProc
    /// thread, normally already capture-time resampled to 16 kHz mono (raw
    /// device rate only on the resampler-nil fallback) — the feed's consumer
    /// runs them through `LiveAudioResampler`, which passes 16 kHz mono
    /// through unchanged.
    var appSink: LiveAudioSink {
        appFeed.sink
    }

    /// `verboseDiagnostics` stays the LAST parameter so a trailing closure binds
    /// to it (matching every existing call site + SwiftFormat's trailing-closure
    /// rule). `eouSessionFactory` therefore must always be passed LABELED, never
    /// as a trailing closure — its `() -> any EouStreamingAsrManaging` shape is
    /// mutually incompatible with `verboseDiagnostics`' `() -> Bool`.
    init(
        engine: (any StreamingTranscribingEngine)?,
        vad: FluidVAD,
        captions: LiveCaptionsState,
        speakerMatcher: any LiveSpeakerMatching = LiveSpeakerMatcher(),
        englishStreaming: Bool = false,
        eouSessionFactory: @escaping EouSessionFactory = LiveTranscriptionController.makeDefaultEouManager,
        verboseDiagnostics: @escaping () -> Bool = { false },
    ) {
        self.engine = engine
        self.vad = vad
        self.captions = captions
        self.speakerMatcher = speakerMatcher
        self.englishStreaming = englishStreaming
        self.eouSessionFactory = eouSessionFactory
        self.verboseDiagnostics = verboseDiagnostics
    }

    /// Production EOU backend: FluidAudio's cache-aware streaming Parakeet EOU
    /// manager at the 320 ms chunk size (WER/latency trade-off) with the
    /// default 1280 ms end-of-utterance debounce. Built lazily, one per channel,
    /// only when the English-streaming path is taken.
    static func makeDefaultEouManager() -> any EouStreamingAsrManaging {
        StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
    }

    /// Warm the engine + VAD + speaker-matcher models and build both channel
    /// pipelines. Sequential re-calls are no-ops (pipelines are only built
    /// once); it is dispatched exactly once per controller instance, from
    /// `LiveTranscriptionCoordinator.ensureController()` — concurrent calls
    /// are not defended against and must not be introduced.
    ///
    /// When `englishStreaming` is on, builds the low-latency EOU sessions; if
    /// their model load throws (e.g. first-use download offline) it logs and
    /// degrades to the re-transcribe path when the active engine supports it,
    /// or to no captions when it doesn't. A failed EOU load
    /// is **not** retried until the controller is rebuilt (a settings change or
    /// relaunch drops + re-creates it) — deliberate, so a failing first-use model
    /// download isn't re-hammered on every recording.
    func prepare() async {
        await prewarmSpeakerMatcher()
        if micPipeline == nil, appPipeline == nil {
            await buildPipelines()
            // Arm the feeds here too (not only in `prepareForNextRecording()`)
            // so the late-resolution ordering — recording already running,
            // EOU models finishing their first-use load — connects the sinks
            // mid-recording instead of staying dark until the next one.
            await bindFeeds()
        }
        strategyResolved = true
        if verboseDiagnostics() {
            // Strategy named explicitly: with the English opt-in on, a silent
            // fallback to re-transcribe is otherwise indistinguishable from the
            // EOU path in the unified log (live-diagnosis seam, no content).
            let strategy = usingEnglishStreaming
                ? "english-streaming"
                : (micPipeline != nil ? "re-transcribe" : "none")
            logger.info(
                "Live transcription ready (strategy: \(strategy, privacy: .public), engine: \(String(describing: type(of: self.engine)), privacy: .public))",
            )
        }
    }

    /// Resolve + construct both channel pipelines per the active strategy.
    private func buildPipelines() async {
        // SPIKE env-gate: force German Nemotron streaming captions whenever live
        // captions are armed, independent of the English opt-in. Used to measure
        // CPU/RAM of the Nemotron path; falls through to the normal strategies if
        // the model load fails.
        if ProcessInfo.processInfo.environment["MEETINGTRANSCRIBER_NEMOTRON_CAPTIONS"] == "1",
           await buildNemotronPipelines() {
            return
        }
        if englishStreaming, await buildEnglishStreamingPipelines() {
            return
        }
        // Re-transcribe path (default, or EOU fallback). Needs a streaming
        // engine; if there is none (English-streaming opt-in with a
        // non-streaming engine that then failed to load EOU models) captions
        // stay off for this session.
        guard let engine else { return }
        await engine.loadModel()
        micPipeline = makeReTranscribePipeline(channel: .mic, engine: engine)
        appPipeline = makeReTranscribePipeline(channel: .app, engine: engine)
    }

    /// Build EOU sessions for both channels, loading their models. Returns true
    /// when both are ready, false (and leaves both pipelines nil) when the load
    /// throws so the caller can fall back.
    private func buildEnglishStreamingPipelines() async -> Bool {
        do {
            let mic = makeEouPipeline(channel: .mic)
            try await mic.prepare()
            let app = makeEouPipeline(channel: .app)
            try await app.prepare()
            micPipeline = mic
            appPipeline = app
            usingEnglishStreaming = true
            return true
        } catch {
            // Non-fatal: log and let the caller fall back to the re-transcribe
            // path (or no captions). Model-load errors carry no spoken content.
            logger.warning("EOU streaming model load failed, falling back: \(error.localizedDescription, privacy: .public)")
            micPipeline = nil
            appPipeline = nil
            usingEnglishStreaming = false
            return false
        }
    }

    /// SPIKE: build German Nemotron streaming sessions for both channels,
    /// sharing one preloaded model set. Returns true on success; false (and
    /// leaves pipelines nil) on load failure so the caller falls back.
    private func buildNemotronPipelines() async -> Bool {
        do {
            let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: "de-DE", chunkMs: 2240,
            )
            let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: dir)
            let mic = makeNemotronPipeline(channel: .mic, shared: shared)
            try await mic.prepare()
            let app = makeNemotronPipeline(channel: .app, shared: shared)
            try await app.prepare()
            micPipeline = mic
            appPipeline = app
            usingEnglishStreaming = true // kept-session path (reused across recordings)
            logger.info("Nemotron streaming captions active (de-DE, shared models)")
            return true
        } catch {
            logger.warning("Nemotron streaming model load failed, falling back: \(error.localizedDescription, privacy: .public)")
            micPipeline = nil
            appPipeline = nil
            usingEnglishStreaming = false
            return false
        }
    }

    private func makeNemotronPipeline(
        channel: LiveCaptionChannel,
        shared: SharedNemotronMultilingualModels,
    ) -> NemotronStreamingCaptionSession {
        let logChannel = channel.rawValue
        return NemotronStreamingCaptionSession(
            shared: shared,
            languageCode: "de-DE",
            channelLabel: logChannel,
            onEvent: makeEventSink(channel: channel, logChannel: logChannel),
        )
    }

    private func prewarmSpeakerMatcher() async {
        do {
            try await speakerMatcher.prepare()
        } catch {
            // Matcher load failure is non-fatal: the controller still
            // produces captions, just without per-utterance speaker names.
            // `LiveSpeakerMatcher.match(audio:)` returns nil on cold-load
            // errors → channel default fallback at the caption call site.
            logger.warning("speaker matcher prewarm failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Recording stopped — retire the feeds, then flush both channel
    /// pipelines so any pending tail utterance (speech that was still in
    /// progress when the recorder stopped, so VAD never emitted a
    /// `speechEnd`) is committed as a final. Must run at STOP time, before
    /// the next recording's `prepareForNextRecording()` clears caption state.
    ///
    /// Retiring first is the completeness barrier: it stops accepting new
    /// deliveries and drains everything the recorder already handed over
    /// into the pipelines, so the pipeline flush below sees the full tail
    /// instead of racing buffers still in flight. Awaits both channels
    /// concurrently afterwards.
    ///
    /// The work is wrapped in a stored `pendingFlush` Task so the next
    /// recording's `prepareForNextRecording()` can await it: a kept EOU session
    /// is reused across recordings, so a slow `asr.finish()` here must finish
    /// before the next recording ingests into the same actor. Awaiting the task's
    /// value keeps `flush()`'s own callers (e.g. the stop-transition handler)
    /// synchronous with completion, exactly as before.
    func flush() async {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.retireFeeds()
            async let mic: Void? = self.micPipeline?.flush()
            async let app: Void? = self.appPipeline?.flush()
            _ = await (mic, app)
        }
        pendingFlush = task
        await task.value
    }

    /// Prepare accumulated state for the next recording. Awaits any in-flight
    /// stop-time `flush()` FIRST so a kept EOU session is fully drained before
    /// the new recording reuses it — otherwise the late flush and the new
    /// recording's ingests interleave on the same actor. Keeps engine + VAD
    /// models loaded; re-creating the re-transcribe actors + feeds is cheap.
    ///
    /// Construction is single-owner and branches on the CONFIG flag, not the
    /// resolved strategy, so a reset-before-`prepare()` ordering doesn't build
    /// the wrong pipelines:
    ///   - EOU resolved (English streaming live): keep the sessions (each was
    ///     drained by its own `flush()`); just re-arm feeds + clear captions.
    ///   - English opt-in but not yet resolved: build nothing — let the pending
    ///     `prepare()` own EOU/fallback construction. With no pipelines there
    ///     are no feeds either, so sink deliveries are dropped — deliberate:
    ///     blocking here until the EOU models load (cold first-use download
    ///     can take ~20 s) would delay recorder.start() and lose actual
    ///     meeting audio, which is far worse than missing the first caption.
    ///   - Otherwise (re-transcribe path, default OR post-EOU-failure fallback):
    ///     rebuild the cheap re-transcribe actors so no stale VAD/transcriber
    ///     state carries across recordings.
    ///
    /// `bindFeeds()` re-arms one fresh feed per existing pipeline (the app
    /// feed gets a fresh `LiveAudioResampler`, replacing the old per-recording
    /// reset of a shared instance).
    func prepareForNextRecording() async {
        await pendingFlush?.value
        pendingFlush = nil

        if usingEnglishStreaming {
            // EOU sessions kept (already drained by flush()).
        } else if englishStreaming, !strategyResolved {
            // EOU opted-in but prepare() hasn't resolved yet → defer to
            // prepare(), which also arms the feeds once it built the pipelines.
        } else if let engine {
            micPipeline = makeReTranscribePipeline(channel: .mic, engine: engine)
            appPipeline = makeReTranscribePipeline(channel: .app, engine: engine)
        }
        await bindFeeds()
        captions.clear()
        if verboseDiagnostics() {
            logger.info("Live transcription reset for new recording")
        }
    }

    /// Retire both channel feeds: stop accepting sink deliveries, then await
    /// the consumers so every buffer already delivered is ingested. This is
    /// the deterministic "all pre-stop audio is in the pipelines" barrier
    /// that `flush()` and a rebind rely on.
    private func retireFeeds() async {
        await micFeed.retire()
        await appFeed.retire()
    }

    /// (Re)arm one bounded feed per built pipeline, retiring any previous
    /// feeds first (also for channels whose pipeline is nil, so no stale
    /// consumer survives a build-less reset). The app feed's consumer runs a
    /// fresh `LiveAudioResampler` per recording, replacing the old shared
    /// instance + per-recording reset.
    private func bindFeeds() async {
        await retireFeeds()
        if let micPipeline {
            await micFeed.bind(to: micPipeline)
        }
        if let appPipeline {
            await appFeed.bind(to: appPipeline) {
                let resampler = LiveAudioResampler()
                return { resampler.resample($0) }
            }
        }
    }

    /// Build the engine-independent low-latency English streaming session for one
    /// channel. The backend manager is built via the injected factory (default:
    /// real Parakeet EOU manager) so each channel gets its own instance.
    private func makeEouPipeline(channel: LiveCaptionChannel) -> EouStreamingCaptionSession {
        let logChannel = channel.rawValue
        return EouStreamingCaptionSession(
            asr: eouSessionFactory(),
            channelLabel: logChannel,
            onEvent: makeEventSink(channel: channel, logChannel: logChannel),
        )
    }

    private func makeReTranscribePipeline(
        channel: LiveCaptionChannel,
        engine: any StreamingTranscribingEngine,
    ) -> any LiveCaptionPipeline {
        // `EngineProxy` is `@unchecked Sendable` so the `@Sendable` closure
        // below can capture it. Safe because every call routes through the
        // engine's `@MainActor`-isolated `transcribeSamples`, which hops back
        // to the main actor on every invocation.
        let proxy = EngineProxy(engine: engine)
        let logChannel = channel.rawValue
        return StreamingTranscriber(
            channelLabel: logChannel,
            vad: vad,
            transcribe: { samples in
                try await proxy.transcribeSamples(samples)
            },
            onEvent: makeEventSink(channel: channel, logChannel: logChannel),
        )
    }

    /// Shared partial/final sink for both pipeline strategies: applies the
    /// partial as ghost text, resolves the speaker via the live matcher on each
    /// final, and routes both into `LiveCaptionsState`. Caption text is gated +
    /// `.private` so spoken content never lands in the unified log by default.
    ///
    /// Log prefix uses the raw channel id, not the user-visible speaker label:
    /// the label is resolved per final (so it may differ per utterance) and the
    /// log args here are `.public` — a matched name would leak enrolled speaker
    /// identities into the unified log.
    private func makeEventSink(
        channel: LiveCaptionChannel,
        logChannel: String,
    ) -> StreamingTranscriber.EventSink {
        { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
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
                    let matched = await self.speakerMatcher.match(audio: audio)
                    let speaker = matched ?? self.captions.label(for: channel)
                    self.captions.applyFinalized(text, channel: channel, speaker: speaker)
                }
            }
        }
    }
}

/// One channel's bounded sink → pipeline feed: an `AsyncStream` whose
/// continuation lives in a lock-guarded slot (the audio callback yields into
/// it synchronously) plus a single detached consumer task that ingests into
/// the channel's `LiveCaptionPipeline` in arrival order. Owning slot and
/// consumer in one type keeps the invariant "exactly one consumer per slot;
/// retire before rebind" in one place instead of mirrored per channel.
///
/// A nil slot — before the first `bind`, or after `retire` — drops yielded
/// buffers, which is correct in every such window: there is either no
/// recording, no pipeline yet (EOU models still loading), or the recording
/// just stopped.
@MainActor
private final class CaptionChannelFeed {
    /// Per-buffer normalization run inside the consumer task. Returning nil
    /// drops the buffer.
    typealias Transform = (LiveAudioBuffer) -> LiveAudioBuffer?

    /// Bounded feed capacity, in buffers. Capture delivers roughly 10–50
    /// buffers/s per channel, so this is tens of seconds of headroom — far
    /// more than a healthy pipeline ever queues in real time, but a hard
    /// bound when inference stalls: the stream then drops the OLDEST buffers
    /// (captions degrade toward the newest audio instead of memory growing
    /// without limit). Sized to hold the ENTIRE 49.8 s E2E fixture (623 ×
    /// 80 ms chunks, burst at ~40× real time by `LiveTranscriptionE2ETests`)
    /// even if the consumer is parked in a slow first inference on the
    /// CPU-only CI runner — those tests rely on lossless delivery.
    private static let capacity = 1024

    /// Cross-thread continuation slot the sink closure yields into. The
    /// audio callback thread yields under the lock; the main actor swaps the
    /// continuation per recording (`bind` / `retire`).
    private let slot = OSAllocatedUnfairLock<AsyncStream<LiveAudioBuffer>.Continuation?>(initialState: nil)
    /// Single consumer task — the serialization that makes
    /// `LiveCaptionPipeline.ingest` calls ordered by construction.
    /// Lock-boxed (not a plain var) for two reasons: `deinit` is nonisolated
    /// and must be able to cancel it, and `retire()` must take exactly the
    /// task it will await so a concurrent rebind's fresh consumer can never
    /// be clobbered by `retire()`'s post-await cleanup.
    private let consumerBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// The owner can be dropped mid-recording (`LiveTranscriptionCoordinator`
    /// nils the controller on a settings change) while the recorder still
    /// holds the sink closure — which captures only the slot storage, not the
    /// feed. Without this, the armed stream and its consumer would keep
    /// running inference for the rest of the recording with every result
    /// discarded (the event sink's weak controller is gone). Cancel stops the
    /// consumer at the next buffer boundary; finishing the slot stops new
    /// deliveries immediately.
    deinit {
        consumerBox.withLock { task in
            task?.cancel()
            task = nil
        }
        slot.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }
    }

    /// Sink closure for the recorder: yields into the currently-armed stream
    /// and returns immediately — no task spawn, no actor hop on the audio
    /// thread. Captures only the slot, never the feed or its owner.
    var sink: LiveAudioSink {
        let slot = slot
        return { buffer in
            slot.withLock { continuation in
                _ = continuation?.yield(buffer)
            }
        }
    }

    /// Arm a fresh feed into `pipeline`, retiring any previous one first so
    /// exactly one consumer exists. `makeTransform` is invoked inside the
    /// consumer task, so a stateful non-Sendable transform (the app channel's
    /// `LiveAudioResampler`) stays confined to it — and is fresh per feed ==
    /// per recording.
    func bind(
        to pipeline: any LiveCaptionPipeline,
        makeTransform: @escaping @Sendable () -> Transform = { \.self },
    ) async {
        await retire()
        let (stream, continuation) = AsyncStream.makeStream(
            of: LiveAudioBuffer.self,
            bufferingPolicy: .bufferingNewest(Self.capacity),
        )
        slot.withLock { $0 = continuation }
        let consumer = Task.detached(priority: .userInitiated) {
            let transform = makeTransform()
            for await buffer in stream {
                guard let normalized = transform(buffer) else { continue }
                await pipeline.ingest(normalized)
            }
        }
        consumerBox.withLock { $0 = consumer }
    }

    /// Stop accepting sink deliveries, then await the consumer so every
    /// buffer already delivered is ingested. Idempotent. Takes the task out
    /// of the box BEFORE awaiting — a rebind that interleaves at the await
    /// installs its fresh consumer into the (now empty) box, untouched by
    /// this call's cleanup.
    func retire() async {
        slot.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }
        let retiring = consumerBox.withLock { task -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        if let retiring { await retiring.value }
    }
}

/// Bridge from a `@MainActor`-isolated `TranscribingEngine` reference into a
/// `@Sendable` async closure passed to `StreamingTranscriber`. The captured
/// engine is only ever called via `await transcribeSamples(_:)`, which is
/// itself main-actor-isolated and hops back to the main actor automatically.
/// `@unchecked Sendable` is the explicit "we know what we're doing" marker
/// the Swift 6 sender-checking requires for this pattern.
private struct EngineProxy: @unchecked Sendable {
    let engine: any StreamingTranscribingEngine

    func transcribeSamples(_ samples: [Float]) async throws -> String {
        try await engine.transcribeSamples(samples)
    }
}
