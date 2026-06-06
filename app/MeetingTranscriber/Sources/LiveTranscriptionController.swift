import AudioTapLib
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

/// PoC controller that wires `StreamingTranscriber` actors to both audio
/// sinks of a `DualSourceRecorder`. Logs partial/final captions via os_log
/// on subsystem `com.meetingtranscriber.app`, category `LiveTranscription`,
/// and feeds them into the observable `LiveCaptionsState` that backs the
/// caption-bar overlay.
///
/// PoC scope:
///   - mic + app channels supported. App-channel buffers (typically 48 kHz
///     interleaved stereo from `CATapDescription`) are downsampled to
///     16 kHz mono via `LiveAudioResampler` before reaching the engine.
///     Mic buffers arrive 16 kHz mono already (post-`MicCaptureHandler`
///     resample) and pass through unchanged.
///   - one engine instance shared by both channels (Parakeet today —
///     other engines fall back to `TranscriptionError.streamingNotSupported`).
///
/// Lifecycle:
///   1. `prepare()` warms the engine + VAD model.
///   2. Caller installs `micSink` and `appSink` on the recorder before
///      `recorder.start(...)`.
///   3. `reset()` clears accumulated state between recordings (keeps models
///      loaded — re-creating the streaming actors + resampler is cheap).
@MainActor
final class LiveTranscriptionController {
    private let engine: any StreamingTranscribingEngine
    private let vad: FluidVAD
    private let captions: LiveCaptionsState
    private let speakerMatcher: any LiveSpeakerMatching
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
    private var appResampler = LiveAudioResampler()

    /// Mic-channel live sink. Hand this to `DualSourceRecorder.micLiveSink`
    /// before `recorder.start(...)`. Buffers arrive on the AVAudioEngine tap
    /// thread; the closure hops onto an actor task and returns immediately.
    var micSink: LiveAudioSink {
        { [weak self] buffer in
            guard let self else { return }
            Task { await self.handleMicBuffer(buffer) }
        }
    }

    /// App-channel live sink. Hand this to `DualSourceRecorder.appLiveSink`
    /// before `recorder.start(...)`. Buffers arrive on the CATap IOProc
    /// thread at the device's native rate (typically 48 kHz stereo) — the
    /// closure dispatches onto the actor, where `LiveAudioResampler` brings
    /// them to 16 kHz mono before the streaming transcriber sees them.
    var appSink: LiveAudioSink {
        { [weak self] buffer in
            guard let self else { return }
            Task { await self.handleAppBuffer(buffer) }
        }
    }

    init(
        engine: any StreamingTranscribingEngine,
        vad: FluidVAD,
        captions: LiveCaptionsState,
        speakerMatcher: any LiveSpeakerMatching = LiveSpeakerMatcher(),
        verboseDiagnostics: @escaping () -> Bool = { false },
    ) {
        self.engine = engine
        self.vad = vad
        self.captions = captions
        self.speakerMatcher = speakerMatcher
        self.verboseDiagnostics = verboseDiagnostics
    }

    /// Warm the engine + VAD + speaker-matcher models. Safe to call
    /// multiple times — each loader dedupes concurrent calls internally.
    func prepare() async {
        await engine.loadModel()
        await prewarmSpeakerMatcher()
        if micPipeline == nil {
            micPipeline = makePipeline(channel: .mic)
        }
        if appPipeline == nil {
            appPipeline = makePipeline(channel: .app)
        }
        if verboseDiagnostics() {
            logger.info("Live transcription ready (engine: \(String(describing: type(of: self.engine)), privacy: .public))")
        }
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

    /// Reset accumulated state for the next recording. Keeps engine + VAD
    /// models loaded — re-creating the actors + resampler is cheap.
    func reset() {
        micPipeline = makePipeline(channel: .mic)
        appPipeline = makePipeline(channel: .app)
        appResampler = LiveAudioResampler()
        captions.clear()
        if verboseDiagnostics() {
            logger.info("Live transcription reset for new recording")
        }
    }

    private func makePipeline(channel: LiveCaptionChannel) -> any LiveCaptionPipeline {
        // `EngineProxy` is `@unchecked Sendable` so the `@Sendable` closure
        // below can capture it. Safe because every call routes through the
        // engine's `@MainActor`-isolated `transcribeSamples`, which hops back
        // to the main actor on every invocation.
        let proxy = EngineProxy(engine: engine)
        // Log prefix uses the raw channel id, not the user-visible speaker
        // label. The speaker label is resolved by the live matcher per final
        // (so the value may differ per utterance) and the log args here are
        // `.public` — using a matched name would leak enrolled speaker
        // identities into the unified log.
        let logChannel = channel.rawValue
        return StreamingTranscriber(
            channelLabel: logChannel,
            vad: vad,
            transcribe: { samples in
                try await proxy.transcribeSamples(samples)
            },
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case let .partial(text):
                        if self.verboseDiagnostics() {
                            // `.private` on `text` masks the spoken content
                            // in `log show` / Console.app unless the system
                            // is in Private Data Capture mode. Defence in
                            // depth on top of the gate.
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
            },
        )
    }

    private func handleMicBuffer(_ buffer: LiveAudioBuffer) async {
        guard let micPipeline else { return }
        await micPipeline.ingest(buffer)
    }

    private func handleAppBuffer(_ buffer: LiveAudioBuffer) async {
        guard let appPipeline,
              let normalized = appResampler.resample(buffer)
        else { return }
        await appPipeline.ingest(normalized)
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
