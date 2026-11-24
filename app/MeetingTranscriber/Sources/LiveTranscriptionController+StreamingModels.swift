import FluidAudio
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

// The streaming caption models (Nemotron, Parakeet EOU): which set a controller
// loads, how its files are downloaded ahead of `prepare()` without two controllers
// downloading the same set at once, and the English EOU pipeline build.

extension LiveTranscriptionController {
    /// A streaming caption model set.
    enum StreamingModel: Equatable {
        case nemotron(languageCode: String)
        case eou

        var name: String {
            switch self {
            case .nemotron: "Nemotron"
            case .eou: "Parakeet EOU"
            }
        }

        /// The `modelDownloads` key: the folder the files go to, not the language,
        /// since Nemotron languages share a variant (de/es/fr/it/pt use the Latin one).
        var downloadKey: String {
            switch self {
            case let .nemotron(languageCode):
                "Nemotron \(StreamingNemotronMultilingualAsrManager.languageDirectory(for: languageCode))"

            case .eou: name
            }
        }
    }

    /// Fetches the files of a streaming model set that are missing, without loading them.
    typealias StreamingModelDownload = @MainActor (StreamingModel) async throws -> Void

    /// The chunk size both the Nemotron download and its load ask for.
    static let nemotronChunkMs = 2240

    /// The model set `prepare()` would load, nil when it loads none (re-transcribe,
    /// language detection, or pipelines already built).
    var streamingModel: StreamingModel? {
        guard micPipeline == nil, appPipeline == nil else { return nil }
        switch captionStrategy {
        case .nemotronStreaming: return engineLanguage.map { .nemotron(languageCode: $0) }
        case .englishStreaming: return .eou
        case .reTranscribe, .none: return nil
        }
    }

    /// Download the streaming models `prepare()` is about to load, when files are
    /// missing. The coordinator awaits this before it queues `prepare()`, so the stall
    /// deadline does not count a network-bound download. Downloads of one model set
    /// run one at a time across controllers (`modelDownloads`); loads are not gated.
    /// A failure becomes the streaming load failure, so `prepare()` falls back without
    /// a load that would download again outside the gate (see transcription.md).
    func downloadStreamingModels() async {
        guard let download = streamingModelDownload, let model = streamingModel else { return }
        do {
            try await modelDownloads.run(model.downloadKey) {
                guard !prepareCancelled else { return }
                try await step("\(model.name) model download") { try await download(model) }
            }
        } catch {
            logger.warning(
                "\(model.name, privacy: .public) model download failed, falling back: \(error.localizedDescription, privacy: .public)",
            )
            streamingLoadFailure = error.localizedDescription
        }
    }

    /// Production download, with FluidAudio's own cache check, so files already
    /// present are not fetched again.
    static func downloadStreamingModel(_ model: StreamingModel) async throws {
        switch model {
        case let .nemotron(languageCode):
            _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: languageCode, chunkMs: nemotronChunkMs,
            )

        case .eou:
            // What `StreamingEouAsrManager.loadModels()` runs before it loads, with an
            // empty load: the same repo (320 ms, as `makeDefaultEouManager` builds),
            // required files and root folder, whose default FluidAudio keeps private.
            try await ModelHub.loadWithRecovery(
                .parakeetEou320,
                directory: MLModelConfigurationUtils.defaultModelsDirectory()
                    .appendingPathComponent("parakeet-eou-streaming", isDirectory: true),
                requiredFiles: ModelNames.ParakeetEOU.requiredModels,
            ) {}
        }
    }

    /// Build EOU sessions for both channels, loading their models. Returns true
    /// when both are ready, false (and leaves both pipelines nil) when the load
    /// throws so the caller can fall back.
    func buildEnglishStreamingPipelines() async -> Bool {
        do {
            let mic = makeEouPipeline(channel: .mic)
            try await step("EOU models, mic channel") { try await mic.prepare() }
            guard !prepareCancelled else { return true }
            let app = makeEouPipeline(channel: .app)
            try await step("EOU models, app channel") { try await app.prepare() }
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

    /// Production EOU backend: FluidAudio's cache-aware streaming Parakeet EOU
    /// manager at the 320 ms chunk size (WER/latency trade-off) with the
    /// default 1280 ms end-of-utterance debounce. Built lazily, one per channel,
    /// only when the English-streaming path is taken.
    static func makeDefaultEouManager() -> any EouStreamingAsrManaging {
        StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
    }
}
