import Foundation

/// Whisper's translation task produces English, not an arbitrary target language.
enum WhisperOutputMode: String, Codable, CaseIterable, Sendable {
    case original
    case translateToEnglish = "translate_to_english"

    var label: String {
        switch self {
        case .original: "Original language"
        case .translateToEnglish: "Translate to English"
        }
    }

    static func supportsTranslation(modelVariant: String) -> Bool {
        // Only the multilingual models offered by our picker are admitted.
        // Turbo is multilingual but was not trained for translation.
        [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v2", "openai_whisper-large-v3-v20240930",
        ].contains(modelVariant)
    }
}

/// Captured once per recording/import. Optional on PipelineJob for old snapshots.
struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    var whisper: WhisperConfiguration?

    struct WhisperConfiguration: Codable, Equatable, Sendable {
        let modelVariant: String
        let language: String?
        var outputMode: WhisperOutputMode

        var translationUnavailable: Bool {
            outputMode == .translateToEnglish
                && !WhisperOutputMode.supportsTranslation(modelVariant: modelVariant)
        }
    }
}

extension TranscribingEngine {
    var transcriptionConfiguration: TranscriptionConfiguration {
        TranscriptionConfiguration(whisper: (self as? WhisperKitEngine)?.configuration)
    }

    /// Freeze Whisper's task, source language and model without duplicating an
    /// already-loaded CoreML pipeline. Other engines retain their existing behavior.
    func session(for configuration: TranscriptionConfiguration) -> any TranscribingEngine {
        if let whisper = configuration.whisper {
            return WhisperTranscriptionSession(base: (self as? WhisperKitEngine) ?? WhisperKitEngine(), configuration: whisper)
        }
        guard let base = self as? WhisperKitEngine else { return self }
        var original = base.configuration
        original.outputMode = .original
        return WhisperTranscriptionSession(base: base, configuration: original)
    }
}
