import SwiftUI

/// The cloud transcription members of the Transcription settings tab. An
/// extension so the view's main body stays under the type-length limit.
extension TranscriptionSettingsView {
    /// Names the local engine and model Run Locally falls back to, e.g.
    /// "Run Locally uses WhisperKit · Large V3 Turbo".
    static func localFallbackDescription(for settings: AppSettings) -> String {
        switch settings.transcriptionEngine {
        case .parakeet:
            return "Run Locally uses Parakeet"

        case .whisperKit:
            let model = settings.whisperKitModelSelection
            var name = model.variant
            if model.origin == .stock, let stock = whisperKitModels.first(where: { $0.variant == model.variant }) {
                name = stock.label.replacingOccurrences(of: " (recommended)", with: "")
            }
            return "Run Locally uses WhisperKit \u{00B7} \(name)"
        }
    }

    @ViewBuilder var captionsOffForCloudNote: some View {
        if captionsOffForCloud {
            Self.footnote("Live captions are off for this language while cloud transcription is on.")
                .accessibilityIdentifier(A11yID.liveCaptionsCloudOffNote)
        }
    }

    /// Live captions are on, but cloud transcription keeps them off for the
    /// current language (they would need the local engine).
    private var captionsOffForCloud: Bool {
        settings.liveTranscriptionEnabled && settings.cloudTranscriptionEnabled
            && LiveCaptionsGate.offForCloud(
                engineLanguage: settings.liveCaptionsLanguageOrNil,
                engineSupportsLive: settings.transcriptionEngine.supportsLiveTranscription,
            )
    }

    static let cloudVocabularyHelpText = "Text file with one term per line. Cloud transcription sends the "
        + "first terms that fit in 128 characters as the request's prompt, a hint rather than a guaranteed "
        + "correction. Run Locally uses the file the way the local engine does."
}
