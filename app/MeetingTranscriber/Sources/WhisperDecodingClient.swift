import WhisperKit

// swiftlint:disable discouraged_optional_collection

/// The narrow decode boundary used by `WhisperKitEngine`. Production forwards
/// to WhisperKit; tests capture the exact options that each public engine flow
/// hands to this boundary without loading a CoreML model.
@MainActor
protocol WhisperDecodingClient: AnyObject {
    var tokenizer: (any WhisperTokenizer)? { get }

    func transcribeFile(
        audioPaths: [String],
        decodeOptions: DecodingOptions,
        callback: @escaping TranscriptionCallback,
    ) async -> [[TranscriptionResult]?]

    func transcribeSamples(
        _ samples: [Float],
        decodeOptions: DecodingOptions,
    ) async throws -> [TranscriptionResult]
}

extension WhisperKit: WhisperDecodingClient {
    func transcribeFile(
        audioPaths: [String],
        decodeOptions: DecodingOptions,
        callback: @escaping TranscriptionCallback,
    ) async -> [[TranscriptionResult]?] {
        await transcribe(audioPaths: audioPaths, decodeOptions: decodeOptions, callback: callback)
    }

    func transcribeSamples(
        _ samples: [Float],
        decodeOptions: DecodingOptions,
    ) async throws -> [TranscriptionResult] {
        try await transcribe(audioArray: samples, decodeOptions: decodeOptions)
    }
}

// swiftlint:enable discouraged_optional_collection
