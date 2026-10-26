import Foundation

/// A recording/job holds its own immutable Whisper settings and decoder reference.
/// A later Settings change may unload the shared engine, but cannot change this
/// session's source language, task or model between partials or between tracks.
@MainActor
final class WhisperTranscriptionSession: StreamingTranscribingEngine {
    private let base: WhisperKitEngine
    let configuration: TranscriptionConfiguration.WhisperConfiguration
    private var resolved: WhisperKitEngine?
    private let preparation = SingleFlight<WhisperKitEngine>()

    init(base: WhisperKitEngine, configuration: TranscriptionConfiguration.WhisperConfiguration) {
        self.base = base
        self.configuration = configuration
    }

    var outputMode: WhisperOutputMode {
        configuration.outputMode
    }

    var modelState: EngineModelState {
        resolved?.modelState ?? base.modelState
    }

    var downloadProgress: Double {
        resolved?.downloadProgress ?? base.downloadProgress
    }

    var transcriptionProgress: Double {
        resolved?.transcriptionProgress ?? 0
    }

    var minimumAudioFrames: Int {
        base.minimumAudioFrames
    }

    func loadModel() async {
        _ = try? await resolve()
    }

    func transcribeSegments(audioPath: URL) async throws -> [TimestampedSegment] {
        let engine = try await resolve()
        return try await engine.transcribeSegments(audioPath: audioPath)
    }

    func transcribeSamples(_ samples: [Float]) async throws -> String {
        let engine = try await resolve()
        return try await engine.transcribeSamples(samples)
    }

    private func resolve() async throws -> WhisperKitEngine {
        guard !configuration.translationUnavailable else {
            throw TranscriptionError.translationModelUnsupported
        }
        if let resolved { return resolved }
        let engine = await preparation.run { [base, configuration] in
            await base.frozenEngine(for: configuration)
        }
        guard engine.hasDecoder else { throw TranscriptionError.modelNotLoaded }
        resolved = engine
        return engine
    }
}
