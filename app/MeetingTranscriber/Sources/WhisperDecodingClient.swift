import WhisperKit

/// The narrow decode boundary used by `WhisperKitEngine`. Production forwards
/// to WhisperKit; tests capture the exact options that each public engine flow
/// hands to this boundary without loading a CoreML model.
@MainActor
protocol WhisperDecodingClient: AnyObject {
    var tokenizer: (any WhisperTokenizer)? { get }

    /// One `Result` per path, in order, so a failure keeps WhisperKit's error.
    func transcribeFile(
        audioPaths: [String],
        decodeOptions: DecodingOptions,
        callback: @escaping TranscriptionCallback,
    ) async -> [Result<[TranscriptionResult], any Error>]

    func transcribeSamples(
        _ samples: [Float],
        decodeOptions: DecodingOptions,
    ) async throws -> [TranscriptionResult]

    /// False for English-only models, whose language detection throws.
    var isMultilingual: Bool { get }

    /// Log probability per language code.
    func languageLogProbabilities(samples: [Float]) async throws -> [String: Float]
}

extension WhisperKit: WhisperDecodingClient {
    func transcribeFile(
        audioPaths: [String],
        decodeOptions: DecodingOptions,
        callback: @escaping TranscriptionCallback,
    ) async -> [Result<[TranscriptionResult], any Error>] {
        await transcribeWithResults(audioPaths: audioPaths, decodeOptions: decodeOptions, callback: callback)
    }

    func transcribeSamples(
        _ samples: [Float],
        decodeOptions: DecodingOptions,
    ) async throws -> [TranscriptionResult] {
        try await transcribe(audioArray: samples, decodeOptions: decodeOptions)
    }

    var isMultilingual: Bool {
        textDecoder.isModelMultilingual
    }

    func languageLogProbabilities(samples: [Float]) async throws -> [String: Float] {
        try await detectLangauge(audioArray: samples).langProbs
    }
}
