import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionSettingsView: View {
    @Bindable var settings: AppSettings
    var whisperKitEngine: WhisperKitEngine
    var parakeetEngine: ParakeetEngine
    var qwen3Engine: (any TranscribingEngine)?

    private static let whisperKitModels: [(variant: String, label: String)] = [
        ("openai_whisper-large-v3-v20240930_turbo", "Large V3 Turbo (recommended)"),
        ("openai_whisper-large-v3-v20240930", "Large V3"),
        ("openai_whisper-large-v2", "Large V2"),
        ("openai_whisper-small", "Small"),
        ("openai_whisper-base", "Base"),
        ("openai_whisper-tiny", "Tiny"),
    ]

    // Visibility relaxed to module-internal so tests can assert picker coverage
    // (see TranscriptionSettingsLanguagePickerTests). Keep in sync with
    // `qwen3Languages` below for the codes both engines support — currently
    // identical except for `""` Auto-detect (WhisperKit-only) and `"uk"`
    // (WhisperKit-only; Qwen3 omits Ukrainian).
    static let whisperLanguages: [(code: String, label: String)] = [
        ("", "Auto-detect"),
        ("de", "Deutsch"),
        ("en", "English"),
        ("fr", "Fran\u{00E7}ais"),
        ("es", "Espa\u{00F1}ol"),
        ("it", "Italiano"),
        ("nl", "Nederlands"),
        ("pt", "Portugu\u{00EA}s"),
        ("ja", "\u{65E5}\u{672C}\u{8A9E}"),
        ("zh", "\u{4E2D}\u{6587}"),
        ("ko", "\u{D55C}\u{AD6D}\u{C5B4}"),
        ("ru", "\u{0420}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}"),
        ("uk", "\u{0423}\u{043A}\u{0440}\u{0430}\u{0457}\u{043D}\u{0441}\u{044C}\u{043A}\u{0430}"),
        ("ar", "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}"),
        ("tr", "T\u{00FC}rk\u{00E7}e"),
        ("hi", "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}"),
        ("th", "\u{0E44}\u{0E17}\u{0E22}"),
        ("vi", "Ti\u{1EBF}ng Vi\u{1EC7}t"),
        ("id", "Bahasa Indonesia"),
        ("ms", "Bahasa Melayu"),
        ("sv", "Svenska"),
        ("da", "Dansk"),
        ("fi", "Suomi"),
        ("pl", "Polski"),
        ("cs", "\u{010C}e\u{0161}tina"),
        ("el", "\u{0395}\u{03BB}\u{03BB}\u{03B7}\u{03BD}\u{03B9}\u{03BA}\u{03AC}"),
        ("hu", "Magyar"),
        ("ro", "Rom\u{00E2}n\u{0103}"),
        ("fa", "\u{0641}\u{0627}\u{0631}\u{0633}\u{06CC}"),
        ("fil", "Filipino"),
        ("mk", "\u{041C}\u{0430}\u{043A}\u{0435}\u{0434}\u{043E}\u{043D}\u{0441}\u{043A}\u{0438}"),
        ("yue", "\u{7CB5}\u{8A9E}"),
    ]

    private static let qwen3Languages: [(code: String, label: String)] = [
        ("de", "Deutsch"),
        ("en", "English"),
        ("fr", "Fran\u{00E7}ais"),
        ("es", "Espa\u{00F1}ol"),
        ("it", "Italiano"),
        ("nl", "Nederlands"),
        ("pt", "Portugu\u{00EA}s"),
        ("ja", "\u{65E5}\u{672C}\u{8A9E}"),
        ("zh", "\u{4E2D}\u{6587}"),
        ("ko", "\u{D55C}\u{AD6D}\u{C5B4}"),
        ("ru", "\u{0420}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}"),
        ("ar", "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}"),
        ("tr", "T\u{00FC}rk\u{00E7}e"),
        ("hi", "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}"),
        ("th", "\u{0E44}\u{0E17}\u{0E22}"),
        ("vi", "Ti\u{1EBF}ng Vi\u{1EC7}t"),
        ("id", "Bahasa Indonesia"),
        ("ms", "Bahasa Melayu"),
        ("sv", "Svenska"),
        ("da", "Dansk"),
        ("fi", "Suomi"),
        ("pl", "Polski"),
        ("cs", "\u{010C}e\u{0161}tina"),
        ("el", "\u{0395}\u{03BB}\u{03BB}\u{03B7}\u{03BD}\u{03B9}\u{03BA}\u{03AC}"),
        ("hu", "Magyar"),
        ("ro", "Rom\u{00E2}n\u{0103}"),
        ("fa", "\u{0641}\u{0627}\u{0631}\u{0633}\u{06CC}"),
        ("fil", "Filipino"),
        ("mk", "\u{041C}\u{0430}\u{043A}\u{0435}\u{0434}\u{043E}\u{043D}\u{0441}\u{043A}\u{0438}"),
        ("yue", "\u{7CB5}\u{8A9E}"),
    ]

    var body: some View {
        // swiftlint:disable:next closure_body_length
        Form {
            // swiftlint:disable:next closure_body_length
            Section("Transcription") {
                Picker("Engine", selection: $settings.transcriptionEngine) {
                    ForEach(TranscriptionEngineSetting.availableCases, id: \.self) { engine in
                        Text(engine.label).tag(engine)
                    }
                }

                if settings.transcriptionEngine == .whisperKit {
                    Picker("Model", selection: $settings.whisperKitModel) {
                        ForEach(Self.whisperKitModels, id: \.variant) { model in
                            Text(model.label).tag(model.variant)
                        }
                    }

                    Picker("Language", selection: $settings.whisperLanguage) {
                        ForEach(Self.whisperLanguages, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                }

                if settings.transcriptionEngine == .parakeet {
                    HStack {
                        TextField("Custom vocabulary file", text: $settings.customVocabularyPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose\u{2026}") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.plainText]
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                settings.customVocabularyPath = url.path
                            }
                        }
                    }
                    .help("Text file with one term per line (e.g. company names, product names)")
                }

                if settings.transcriptionEngine == .qwen3 {
                    Picker("Language", selection: $settings.qwen3Language) {
                        Text("Auto-detect").tag("")
                        ForEach(Self.qwen3Languages, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                }

                engineStatusView
            }
            .accessibilityIdentifier("transcriptionSection")
            .recordOnlyDisabled(settings.recordOnly)
        }
        .formStyle(.grouped)
    }

    private var activeEngine: any TranscribingEngine {
        switch settings.transcriptionEngine {
        case .parakeet: parakeetEngine
        case .qwen3: qwen3Engine ?? whisperKitEngine
        case .whisperKit: whisperKitEngine
        }
    }

    @ViewBuilder
    private var engineStatusView: some View { // swiftlint:disable:this attributes
        let engine = activeEngine
        switch engine.modelState {
        case .downloading:
            ProgressView(value: engine.downloadProgress)
                .progressViewStyle(.linear)
            Text("Downloading model... \(Int(engine.downloadProgress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .loaded:
            Label("Model ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)

        case .unloaded, .unloading:
            Button("Load Model") {
                if settings.transcriptionEngine == .whisperKit {
                    whisperKitEngine.modelVariant = settings.whisperKitModel
                }
                if #available(macOS 15, *), settings.transcriptionEngine == .qwen3,
                   let qe = qwen3Engine as? Qwen3AsrEngine {
                    qe.language = settings.qwen3LanguageOrNil
                }
                Task { await engine.loadModel() }
            }

        case .prewarming, .prewarmed, .downloaded:
            HStack {
                ProgressView().controlSize(.small)
                Text("Preparing model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
