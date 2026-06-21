import FluidAudio

// Nemotron streaming-pipeline construction, split out of LiveTranscriptionController
// (file-length cap) and behind an injectable factory so tests can exercise the
// controller's build + model-load-failure fallback state machine without the
// real ~0.6 GB CoreML model.

extension LiveTranscriptionController {
    /// Builds both channel pipelines for a Nemotron streaming language off one
    /// shared model load. `makeSink` produces the per-channel event sink (speaker
    /// matching + captions routing) so the builder needs no controller-private
    /// state. Injectable; the default loads the real model, tests substitute a
    /// fake that returns mock pipelines or throws (fallback).
    typealias NemotronPipelineFactory = @MainActor (
        _ languageCode: String,
        _ vad: FluidVAD,
        _ makeSink: (LiveCaptionChannel) -> StreamingTranscriber.EventSink,
    ) async throws -> (mic: any LiveCaptionPipeline, app: any LiveCaptionPipeline)

    /// Production builder: download + preload the shared model once, then build
    /// one Nemotron session per channel (each with its own manager + VAD boundary
    /// detector) and load it. Throws on download/preload/load failure so the
    /// caller falls back to re-transcribe.
    static func makeDefaultNemotronPipelines(
        languageCode: String,
        vad: FluidVAD,
        makeSink: (LiveCaptionChannel) -> StreamingTranscriber.EventSink,
    ) async throws -> (mic: any LiveCaptionPipeline, app: any LiveCaptionPipeline) {
        let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: languageCode, chunkMs: 2240,
        )
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: dir)
        func make(_ channel: LiveCaptionChannel) -> NemotronStreamingCaptionSession {
            NemotronStreamingCaptionSession(
                manager: NemotronAsrManager(shared: shared, languageCode: languageCode),
                detector: FluidVADBoundaryDetector(vad: vad),
                channelLabel: channel.rawValue,
                onEvent: makeSink(channel),
            )
        }
        let mic = make(.mic)
        try await mic.prepare()
        let app = make(.app)
        try await app.prepare()
        return (mic, app)
    }
}
