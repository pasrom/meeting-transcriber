import AudioTapLib
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

/// PoC controller that wires a `StreamingTranscriber` to the mic-channel
/// `LiveAudioSink` of a `DualSourceRecorder`. Logs partial/final captions
/// via os_log on subsystem `com.meetingtranscriber.app`,
/// category `LiveTranscription`.
///
/// PoC scope:
///   - mic channel only (16 kHz mono Float32 already, no conversion needed);
///   - one engine (caller supplies any `TranscribingEngine` that overrides
///     `transcribeSamples`; Parakeet is the only one in-tree today);
///   - no UI, no AppState integration — pure logging.
///
/// Lifecycle:
///   1. `prepare()` warms the engine + VAD model.
///   2. Caller installs `micSink` on the recorder before `recorder.start(...)`.
///   3. `reset()` clears accumulated state between recordings (keeps models
///      loaded — re-creating the streaming actor is cheap).
@MainActor
final class LiveTranscriptionController {
    private let engine: any TranscribingEngine
    private let vad: FluidVAD
    private let captions: LiveCaptionsState
    private var transcriber: StreamingTranscriber?

    /// Mic-channel live sink. Hand this to `DualSourceRecorder.micLiveSink`
    /// before `recorder.start(...)`. Buffers arrive on the AVAudioEngine tap
    /// thread; the closure hops onto an actor task and returns immediately.
    var micSink: LiveAudioSink {
        { [weak self] buffer in
            guard let self else { return }
            Task { await self.handleBuffer(buffer) }
        }
    }

    init(
        engine: any TranscribingEngine,
        vad: FluidVAD,
        captions: LiveCaptionsState,
    ) {
        self.engine = engine
        self.vad = vad
        self.captions = captions
    }

    /// Warm the engine + VAD models. Safe to call multiple times — engines
    /// dedupe concurrent `loadModel` calls internally.
    func prepare() async {
        await engine.loadModel()
        // FluidVAD lazily loads on first use; pre-warming would require a
        // dummy chunk through it. Skip for the PoC — first VAD call takes
        // the model-load hit (~200 ms) once at start of recording.
        if transcriber == nil {
            transcriber = makeTranscriber()
        }
        logger.info("Live transcription ready (engine: \(String(describing: type(of: self.engine)), privacy: .public))")
    }

    /// Reset accumulated state for the next recording. Keeps engine + VAD
    /// models loaded — re-creating the actor is cheap.
    func reset() {
        transcriber = makeTranscriber()
        captions.clear()
        logger.info("Live transcription reset for new recording")
    }

    private func makeTranscriber() -> StreamingTranscriber {
        // `EngineProxy` is `@unchecked Sendable` so the `@Sendable` closure
        // below can capture it. Safe because every call routes through the
        // engine's `@MainActor`-isolated `transcribeSamples`, which hops back
        // to the main actor on every invocation.
        let proxy = EngineProxy(engine: engine)
        let captions = captions
        return StreamingTranscriber(
            channelLabel: "mic",
            vad: vad,
            transcribe: { samples in
                try await proxy.transcribeSamples(samples)
            },
            onEvent: { event in
                Task { @MainActor in
                    switch event {
                    case let .partial(text):
                        logger.info("partial: \(text, privacy: .public)")
                        captions.applyPartial(text)

                    case let .finalized(text):
                        logger.info("final: \(text, privacy: .public)")
                        captions.applyFinalized(text)
                    }
                }
            },
        )
    }

    private func handleBuffer(_ buffer: LiveAudioBuffer) async {
        guard let transcriber else { return }
        await transcriber.ingest(buffer)
    }
}

/// Bridge from a `@MainActor`-isolated `TranscribingEngine` reference into a
/// `@Sendable` async closure passed to `StreamingTranscriber`. The captured
/// engine is only ever called via `await transcribeSamples(_:)`, which is
/// itself main-actor-isolated and hops back to the main actor automatically.
/// `@unchecked Sendable` is the explicit "we know what we're doing" marker
/// the Swift 6 sender-checking requires for this pattern.
private struct EngineProxy: @unchecked Sendable {
    let engine: any TranscribingEngine

    func transcribeSamples(_ samples: [Float]) async throws -> String {
        try await engine.transcribeSamples(samples)
    }
}
