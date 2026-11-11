import Foundation

/// Nemotron tokenizer training coverage. Prompt dictionary keys are spellings,
/// not evidence that the model was trained for an additional language.
///
/// The tokenizer's tags are all region-qualified (`<de-DE>`, `<ja-JP>`). The region is
/// dropped on purpose where the tokenizer has one dialect, because the pickers produce
/// bare codes; a hand-set `ja-JP` is therefore not recognised and uses re-transcribe.
enum LiveCaptionLanguages {
    static let trainedTags: Set<String> = [
        "bg", "cs", "da", "de", "el", "et", "fi", "fr", "hu", "hr", "it", "lt", "lv", "nl", "pl",
        "pt-BR", "pt-PT", "ro", "ru", "sk", "sl", "sv", "uk", "ar", "en-GB", "en-US", "es-ES", "es-US",
        "fr-CA", "he", "hi", "ja", "ko", "nb", "nn", "th", "tr", "zh-CN", "vi",
    ]

    private static let aliases = ["en": "en-US", "es": "es-ES", "pt": "pt-BR", "zh": "zh-CN", "no": "nb"]

    static func normalized(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// Bare aliases choose a default dialect; unlisted regional forms stay unsupported.
    static func canonicalTag(for code: String) -> String? {
        let normalized = normalized(code)
        return aliases[normalized] ?? trainedTags.first { $0.lowercased() == normalized }
    }
}
