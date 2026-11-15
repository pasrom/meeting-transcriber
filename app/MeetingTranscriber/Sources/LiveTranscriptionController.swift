import FluidAudio
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

/// Wires the per-channel caption pipelines to both audio sinks of a
/// `DualSourceRecorder`. Logs partial/final captions via os_log on subsystem
/// `com.meetingtranscriber`, category `LiveTranscription`, and feeds them
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
/// Dataflow: each channel has a duration-bounded audio feed.
/// The sink closure yields into the stream synchronously on the audio
/// callback thread; a single detached consumer task per channel ingests into
/// that channel's `LiveCaptionPipeline`. Ordering (single consumer → FIFO)
/// and overflow handling (newest audio wins, with a reset after gaps) belong to the
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
    /// language-driven streaming backends (Nemotron/EOU) are engine-independent:
    /// with a non-streaming active engine there is no streaming engine to hold,
    /// and captions still run via those sessions.
    let engine: (any StreamingTranscribingEngine)?
    let vad: FluidVAD
    let captions: LiveCaptionsState
    private let speakerMatcher: any LiveSpeakerMatching
    /// The active engine's EXPLICITLY-configured language (`de`/`en`/nil), which
    /// picks the streaming backend via `LiveCaptionsGate` (`en` → EOU, a Nemotron-trained
    /// language such as `de` → Nemotron, else → re-transcribe). On a streaming-model load failure
    /// `prepare()` degrades to re-transcribe (if supported) or to no captions.
    private let engineLanguage: String?

    /// Resolved per-channel strategy (`liveEnabled` is implicit — the controller
    /// only exists when captions are eligible).
    private var captionStrategy: LiveCaptionsGate.Strategy {
        LiveCaptionsGate.strategy(
            liveEnabled: true,
            engineLanguage: engineLanguage,
            engineSupportsLive: engine != nil,
        )
    }

    /// True for the engine-independent streaming sessions (German/English), kept
    /// across recordings vs. the rebuilt re-transcribe actors.
    private var isStreamingStrategy: Bool {
        captionStrategy == .nemotronStreaming || captionStrategy == .englishStreaming
    }

    typealias ReTranscribePipelineFactory = @MainActor (
        LiveCaptionChannel, @escaping StreamingTranscriber.TranscribeFunction, @escaping StreamingTranscriber.EventSink,
    ) -> any LiveCaptionPipeline

    /// Per-recording phase of auto-detect captions (`usesLanguageProbe`).
    enum RuntimeState { case detecting, preparing, streaming, keeping, stopping }
    var runtimeState: RuntimeState = .detecting
    var languageDecision = CaptionLanguageProbeDecision()
    let speechDetector: CaptionLanguageProbe.SpeechDetector?
    var detectionArmed = false
    var recordingStartedAt = Date()
    let micProbeFeed: CaptionChannelFeed
    let appProbeFeed: CaptionChannelFeed
    /// Auto-detect on an engine that can detect the language probes it before
    /// captioning, so English can stream through EOU.
    var usesLanguageProbe: Bool {
        engineLanguage == nil && engine?.supportsCaptionLanguageDetection == true
    }

    /// Bumped per auto-detect recording; sinks of an older one drop their events.
    var generation = 0
    var switchTask: Task<Void, Never>?
    var probeArmingTask: Task<Void, Never>?

    /// Auto-detect's EOU model load, at most once per controller: nil on failure, never retried.
    var eouLoad: Task<EouManagers?, Never>?
    private let reTranscribePipelineFactory: ReTranscribePipelineFactory?
    let eouSessionFactory: EouSessionFactory
    private let nemotronPipelineFactory: NemotronPipelineFactory
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
    var micPipeline: (any LiveCaptionPipeline)?
    var appPipeline: (any LiveCaptionPipeline)?

    /// One bounded feed per channel (see `CaptionChannelFeed`). The feeds
    /// are (re)armed per recording via `bindFeeds()` and retired by
    /// `flush()`/`retireFeeds()`.
    let micFeed: CaptionChannelFeed
    let appFeed: CaptionChannelFeed
    /// True once `prepare()` resolved to a kept streaming session (German/English),
    /// which `prepareForNextRecording()` keeps instead of rebuilding.
    var usingStreamingSession = false
    /// True once `prepare()` built the pipelines — distinguishes "not yet resolved"
    /// (pipelines nil → let `prepare()` build) from "resolved to re-transcribe
    /// fallback" (refresh actors), since both have `usingStreamingSession == false`.
    private var strategyResolved = false
    /// Re-transcribe pipelines, including a streaming fallback, run on the shared engine.
    /// The language probe runs on the engine every recording.
    var usesTranscriptionEngine: Bool {
        usesLanguageProbe || (!usingStreamingSession && micPipeline != nil)
    }

    /// Called before `prepare()` loads the shared engine, so the owner can hold its model.
    var willLoadEngine: (() -> Void)?

    /// Why `prepare()` ended with no caption model loaded; nil while it runs and
    /// when captions can run (a fallback to re-transcribe included).
    private(set) var prepareFailure: String?
    private var streamingLoadFailure: String?
    static let engineLoadFailure = "The transcription model could not be loaded."

    /// Set by `cancelPrepare()`; `prepare()` checks it between model loads.
    private var prepareCancelled = false

    /// Stop `prepare()` at its next step. The owner calls this when it drops the
    /// controller; a model load already running is not interrupted.
    func cancelPrepare() {
        prepareCancelled = true
        captions.setDetectingLanguage(false)
    }

    /// The most recent stop-time flush, kept so the NEXT recording's reset can
    /// await it before reusing a kept EOU session. `flush()` is dispatched
    /// fire-and-forget from `WatchingController`, and a slow `asr.finish()` can
    /// otherwise interleave with the next recording's ingests on the same actor —
    /// emitting the old tail as the new recording's caption or zeroing its ring.
    var pendingFlush: Task<Void, Never>?

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
        engineLanguage: String? = nil,
        eouSessionFactory: @escaping EouSessionFactory = LiveTranscriptionController.makeDefaultEouManager,
        nemotronPipelineFactory: @escaping NemotronPipelineFactory = { language, vad, makeSink in
            try await LiveTranscriptionController.makeDefaultNemotronPipelines(
                languageCode: language, vad: vad, makeSink: makeSink,
            )
        },
        // Must exceed the slowest single decode plus the 0.8 s partial gate; see transcription.md.
        reTranscribePipelineFactory: ReTranscribePipelineFactory? = nil,
        maxQueuedSeconds: TimeInterval = 10,
        speechDetector: CaptionLanguageProbe.SpeechDetector? = nil,
        verboseDiagnostics: @escaping () -> Bool = { false },
    ) {
        micFeed = CaptionChannelFeed(maxQueuedSeconds: maxQueuedSeconds)
        appFeed = CaptionChannelFeed(maxQueuedSeconds: maxQueuedSeconds)
        micProbeFeed = CaptionChannelFeed(maxQueuedSeconds: maxQueuedSeconds)
        appProbeFeed = CaptionChannelFeed(maxQueuedSeconds: maxQueuedSeconds)
        self.engine = engine
        self.speechDetector = speechDetector
        self.reTranscribePipelineFactory = reTranscribePipelineFactory
        self.vad = vad
        self.captions = captions
        self.speakerMatcher = speakerMatcher
        self.engineLanguage = engineLanguage
        self.eouSessionFactory = eouSessionFactory
        self.nemotronPipelineFactory = nemotronPipelineFactory
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
    /// pipelines. A re-call never rebuilds the pipelines, but on the
    /// re-transcribe path it loads an engine that is not loaded. It is
    /// dispatched exactly once per controller instance, from
    /// `LiveTranscriptionCoordinator.ensureController()` — concurrent calls
    /// are not defended against and must not be introduced.
    ///
    /// When a streaming language is configured, builds the low-latency streaming
    /// sessions (Nemotron or EOU); if their model load throws (e.g. first-use
    /// download offline) it logs and degrades to the re-transcribe path when the
    /// active engine supports it, or to no captions when it doesn't. A failed
    /// streaming load is **not** retried until the controller is rebuilt (a
    /// settings change or relaunch drops + re-creates it) — deliberate, so a
    /// failing first-use model download isn't re-hammered on every recording.
    func prepare() async {
        guard !prepareCancelled else { return }
        await prewarmSpeakerMatcher()
        guard !prepareCancelled else { return }
        if usesLanguageProbe, let engine {
            await loadEngineForLanguageDetection(engine)
            guard !prepareCancelled else { return }
            await reTranscribeIfDetectionUnsupported(engine)
        }
        if usesLanguageProbe, let engine {
            if !detectionArmed, runtimeState != .stopping { await armLanguageProbe(recording: false) }
            strategyResolved = true
            prepareFailure = engine.modelState == .loaded ? nil : Self.engineLoadFailure
            if verboseDiagnostics() {
                logger.info("Live transcription ready (backend: language detection)")
            }
            return
        }
        if micPipeline == nil, appPipeline == nil {
            await buildPipelines()
            // A dropped controller must not publish its backend over its successor's.
            guard !prepareCancelled else { return }
            // Arm the feeds here too (not only in `prepareForNextRecording()`)
            // so the late-resolution ordering — recording already running,
            // EOU models finishing their first-use load — connects the sinks
            // mid-recording instead of staying dark until the next one.
            await bindFeeds()
        } else if usesTranscriptionEngine, let engine, engine.modelState != .loaded {
            // `prepareForNextRecording()` built the re-transcribe pipelines first; load here
            // so the state below judges a load attempt. `loadModel()` rebuilds a loaded model.
            willLoadEngine?()
            await engine.loadModel()
            guard !prepareCancelled else { return }
        }
        strategyResolved = true
        // Resolve the ACTUAL backend (a failed streaming load shows here as the
        // re-transcribe fallback, not the selected streaming engine) and publish
        // it for the overlay indicator + the diagnostic log.
        let engine: String? = usingStreamingSession
            ? (captionStrategy == .nemotronStreaming ? "Nemotron" : "Parakeet EOU")
            : (micPipeline != nil ? "Re-transcribe" : nil)
        let backend = engine.map { name in
            engineLanguage.map { "\(name) · \($0.uppercased())" } ?? name
        }
        captions.setActiveBackend(backend)
        prepareFailure = if backend == nil {
            streamingLoadFailure ?? "No caption model could be loaded."
        } else if usesTranscriptionEngine, self.engine?.modelState != .loaded {
            // `loadModel()` does not throw. The pipelines stay, so each utterance retries the load.
            streamingLoadFailure ?? Self.engineLoadFailure
        } else {
            nil
        }
        if verboseDiagnostics() {
            logger.info(
                "Live transcription ready (backend: \(backend ?? "none", privacy: .public))",
            )
        }
    }

    /// Construct both channel pipelines per the active strategy; a streaming
    /// backend that fails its model load falls through to re-transcribe.
    private func buildPipelines() async {
        switch captionStrategy {
        case .nemotronStreaming:
            if await buildNemotronStreamingPipelines() { return }

        case .englishStreaming:
            if await buildEnglishStreamingPipelines() { return }

        case .reTranscribe, .none:
            break
        }
        // Re-transcribe path (default or streaming fallback). With no streaming
        // engine (failed streaming backend on a non-streaming engine) captions stay off.
        guard let engine, !prepareCancelled else { return }
        willLoadEngine?()
        await engine.loadModel()
        micPipeline = makeReTranscribePipeline(channel: .mic, engine: engine)
        appPipeline = makeReTranscribePipeline(channel: .app, engine: engine)
    }

    /// Build Nemotron sessions for both channels off one preloaded model set, in
    /// the active engine's language (~611 MB Latin model, shared by de/es/fr/it/pt,
    /// downloads on first use). Returns false on load failure so the caller falls back.
    private func buildNemotronStreamingPipelines() async -> Bool {
        // Reached only via `.nemotronStreaming`, so `engineLanguage` is non-nil.
        guard let languageCode = engineLanguage else { return false }
        do {
            let (mic, app) = try await nemotronPipelineFactory(languageCode, vad) { channel in
                self.makeEventSink(channel: channel, logChannel: channel.rawValue)
            }
            micPipeline = mic
            appPipeline = app
            usingStreamingSession = true
            return true
        } catch {
            logger.warning(
                "Nemotron streaming model load failed, falling back: \(error.localizedDescription, privacy: .public)",
            )
            streamingLoadFailure = error.localizedDescription
            micPipeline = nil
            appPipeline = nil
            usingStreamingSession = false
            return false
        }
    }

    /// Build EOU sessions for both channels, loading their models. Returns true
    /// when both are ready, false (and leaves both pipelines nil) when the load
    /// throws so the caller can fall back.
    private func buildEnglishStreamingPipelines() async -> Bool {
        do {
            let mic = makeEouPipeline(channel: .mic)
            try await mic.prepare()
            guard !prepareCancelled else { return true }
            let app = makeEouPipeline(channel: .app)
            try await app.prepare()
            micPipeline = mic
            appPipeline = app
            usingStreamingSession = true
            return true
        } catch {
            // Non-fatal: log and let the caller fall back to the re-transcribe
            // path (or no captions). Model-load errors carry no spoken content.
            logger.warning("EOU streaming model load failed, falling back: \(error.localizedDescription, privacy: .public)")
            streamingLoadFailure = error.localizedDescription
            micPipeline = nil
            appPipeline = nil
            usingStreamingSession = false
            return false
        }
    }

    private func prewarmSpeakerMatcher() async {
        do {
            try await speakerMatcher.prepare()
        } catch {
            // Matcher load failure is non-fatal: the controller still
            // produces captions, just without per-utterance speaker names.
            // `LiveSpeakerMatcher.match(audio:)` returns `.unknown` on cold-load
            // errors → channel default fallback at the caption call site.
            logger.warning("speaker matcher prewarm failed: \(error.localizedDescription, privacy: .public)")
        }
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
        await probeArmingTask?.value
        // Not awaited: a detection or EOU load from the last recording must not delay
        // this start. The generation bump below drops its result; `eouLoad` keeps the models.
        switchTask?.cancel()
        switchTask = nil
        languageDecision = CaptionLanguageProbeDecision()
        runtimeState = usesLanguageProbe ? .detecting : .keeping
        // A detected language holds for one recording; the next one probes afresh.
        if engineLanguage == nil {
            generation += 1
            usingStreamingSession = false
        }

        if usesLanguageProbe {
            captions.clear()
            await armLanguageProbe(recording: true)
            return
        }

        if usingStreamingSession {
            // Streaming sessions kept (already drained by flush()).
        } else if isStreamingStrategy, !strategyResolved {
            // A streaming backend was selected but prepare() hasn't resolved yet
            // → defer to prepare(), which arms the feeds once it built the pipelines.
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
    func retireFeeds(logDrops: Bool = false) async {
        let micDrops = await micFeed.retire()
        let appDrops = await appFeed.retire()
        guard logDrops, verboseDiagnostics() else { return }
        for (channel, drops) in [("mic", micDrops), ("app", appDrops)] {
            guard let drops else { continue }
            logger.info(
                "[\(channel, privacy: .public)] caption queue dropped \(drops.seconds, format: .fixed(precision: 1), privacy: .public) s in \(drops.gaps, privacy: .public) gaps",
            )
        }
    }

    /// (Re)arm one bounded feed per built pipeline, retiring any previous
    /// feeds first (also for channels whose pipeline is nil, so no stale
    /// consumer survives a build-less reset). The app feed's consumer runs a
    /// fresh `LiveAudioResampler` per recording, replacing the old shared
    /// instance + per-recording reset.
    func bindFeeds() async {
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
    func makeEouPipeline(
        channel: LiveCaptionChannel,
        asr: (any EouStreamingAsrManaging)? = nil,
    ) -> EouStreamingCaptionSession {
        let logChannel = channel.rawValue
        let matcher = speakerMatcher
        return EouStreamingCaptionSession(
            asr: asr ?? eouSessionFactory(),
            channelLabel: logChannel,
            voiceProbe: { await matcher.probe(audio: $0) },
            onEvent: makeEventSink(channel: channel, logChannel: logChannel),
        )
    }

    func makeReTranscribePipeline(
        channel: LiveCaptionChannel,
        engine: any StreamingTranscribingEngine,
    ) -> any LiveCaptionPipeline {
        // `EngineProxy` is `@unchecked Sendable` so the `@Sendable` closure
        // below can capture it. Safe because every call routes through the
        // engine's `@MainActor`-isolated `transcribeSamples`, which hops back
        // to the main actor on every invocation.
        let proxy = EngineProxy(engine: engine)
        let logChannel = channel.rawValue
        let sink = makeEventSink(channel: channel, logChannel: logChannel)
        let transcribe: StreamingTranscriber.TranscribeFunction = { samples in
            try await proxy.transcribeSamples(samples)
        }
        if let reTranscribePipelineFactory { return reTranscribePipelineFactory(channel, transcribe, sink) }
        return StreamingTranscriber(
            channelLabel: logChannel,
            vad: vad,
            transcribe: transcribe,
            onEvent: sink,
        )
    }

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
    private func makeEventSink(
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
