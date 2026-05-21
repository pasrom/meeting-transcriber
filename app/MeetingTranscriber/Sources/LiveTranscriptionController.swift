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
    private let engine: any TranscribingEngine
    private let vad: FluidVAD
    private let captions: LiveCaptionsState
    private var micTranscriber: StreamingTranscriber?
    private var appTranscriber: StreamingTranscriber?
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
        if micTranscriber == nil {
            micTranscriber = makeTranscriber(channel: .mic)
        }
        if appTranscriber == nil {
            appTranscriber = makeTranscriber(channel: .app)
        }
        logger.info("Live transcription ready (engine: \(String(describing: type(of: self.engine)), privacy: .public))")
    }

    /// Reset accumulated state for the next recording. Keeps engine + VAD
    /// models loaded — re-creating the actors + resampler is cheap.
    func reset() {
        micTranscriber = makeTranscriber(channel: .mic)
        appTranscriber = makeTranscriber(channel: .app)
        appResampler = LiveAudioResampler()
        captions.clear()
        logger.info("Live transcription reset for new recording")
    }

    private func makeTranscriber(channel: LiveCaptionChannel) -> StreamingTranscriber {
        // `EngineProxy` is `@unchecked Sendable` so the `@Sendable` closure
        // below can capture it. Safe because every call routes through the
        // engine's `@MainActor`-isolated `transcribeSamples`, which hops back
        // to the main actor on every invocation.
        let proxy = EngineProxy(engine: engine)
        let captions = captions
        return StreamingTranscriber(
            channelLabel: channel.label,
            vad: vad,
            transcribe: { samples in
                try await proxy.transcribeSamples(samples)
            },
            onEvent: { event in
                Task { @MainActor in
                    switch event {
                    case let .partial(text):
                        logger.info("[\(channel.label, privacy: .public)] partial: \(text, privacy: .public)")
                        captions.applyPartial(text, channel: channel)

                    case let .finalized(text):
                        logger.info("[\(channel.label, privacy: .public)] final: \(text, privacy: .public)")
                        captions.applyFinalized(text, channel: channel)
                    }
                }
            },
        )
    }

    private func handleMicBuffer(_ buffer: LiveAudioBuffer) async {
        guard let micTranscriber else { return }
        await micTranscriber.ingest(buffer)
    }

    private func handleAppBuffer(_ buffer: LiveAudioBuffer) async {
        guard let appTranscriber,
              let normalized = appResampler.resample(buffer)
        else { return }
        await appTranscriber.ingest(normalized)
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
