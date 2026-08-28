import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionSettingsView: View {
    @Bindable var settings: AppSettings
    var whisperKitEngine: WhisperKitEngine
    var parakeetEngine: ParakeetEngine

    /// Set when the user flips live captions on while a first-use Nemotron model
    /// download is pending — defers the actual enable to the consent alert.
    @State private var pendingCaptionEnable = false

    private static let whisperKitModels: [(variant: String, label: String)] = [
        ("openai_whisper-large-v3-v20240930_turbo", "Large V3 Turbo (recommended)"),
        ("openai_whisper-large-v3-v20240930", "Large V3"),
        ("openai_whisper-large-v2", "Large V2"),
        ("openai_whisper-small", "Small"),
        ("openai_whisper-base", "Base"),
        ("openai_whisper-tiny", "Tiny"),
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
                        ForEach(PickerLanguages.whisperKit, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                }

                if settings.transcriptionEngine == .parakeet {
                    Picker("Language", selection: $settings.parakeetLanguage) {
                        ForEach(PickerLanguages.parakeet, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                }

                HStack {
                    TextField("Custom vocabulary file", text: Binding(
                        get: { settings.customVocabularyPath },
                        set: { settings.setCustomVocabularyPath($0) },
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(A11yID.customVocabularyPathField)
                    Button("Choose\u{2026}") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.plainText]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.setCustomVocabularyFile(url)
                        }
                    }
                }
                .help(Self.vocabularyHelpText(for: settings.transcriptionEngine))

                Text(settings.customVocabularyValidation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onAppear { settings.refreshCustomVocabularyValidation() }
                    .onChange(of: settings.customVocabularyPath) { _, _ in
                        settings.refreshCustomVocabularyValidation()
                    }
                if settings.transcriptionEngine == .whisperKit {
                    Toggle("Use custom vocabulary prompt (experimental)", isOn: $settings.whisperKitVocabularyPromptEnabled)
                        .accessibilityIdentifier(A11yID.whisperKitVocabularyPromptToggle)
                        .help(Self.whisperKitVocabularyPromptHelpText)
                    Text("Experimental: dense audio can omit whole sentences. See help for measured results; prefer Parakeet for vocabulary boosting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("When enabled, WhisperKit uses a 32-token hint; earlier terms have priority.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Canonical terminology")
                    TextEditor(text: $settings.terminologyRulesText)
                        .font(.body.monospaced())
                        .frame(minHeight: 72)
                        .accessibilityIdentifier(A11yID.terminologyRulesEditor)
                    Text(
                        "Applied to saved transcripts after ASR. One rule per line: "
                            + "Canonical spelling => spoken variant | another variant. "
                            + "Rules only replace whole words or phrases.",
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(settings.terminologyRulesValidation.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                engineStatusView
            }
            .accessibilityIdentifier(A11yID.transcriptionSection)
            .recordOnlyDisabled(settings.recordOnly)

            liveTranscriptionSection
        }
        .formStyle(.grouped)
    }

    /// Hoisted out of `body` into a named property so the section's nesting
    /// doesn't grow the `body` type-check past the 300 ms hard limit on CI.
    private var liveTranscriptionSection: some View {
        Section("Live transcription (PoC)") {
            // The toggle stays enabled even for engines without the
            // re-transcribe hook, because the language-driven streaming
            // backends route captions through an engine-independent session.
            // Enabling it for a Nemotron language whose model isn't downloaded
            // yet defers to a consent alert (the ~0.6 GB first-use download).
            Toggle("Show partial transcripts during recording", isOn: Binding(
                get: { settings.liveTranscriptionEnabled },
                set: { enabled in
                    if enabled, needsCaptionModelConsent {
                        pendingCaptionEnable = true
                    } else {
                        settings.liveTranscriptionEnabled = enabled
                    }
                },
            ))
            .alert("Download caption model?", isPresented: $pendingCaptionEnable) {
                Button("Cancel", role: .cancel) {}
                Button("Enable") { settings.liveTranscriptionEnabled = true }
            } message: {
                Text(
                    "Live captions in this language use a roughly 0.6 GB on-device model, "
                        + "downloaded once on first use.",
                )
            }

            Text(captionBackendFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(liveTranscriptionFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(A11yID.liveTranscriptionSection)
        .recordOnlyDisabled(settings.recordOnly)
    }

    /// True when enabling captions would trigger the first-use Nemotron download:
    /// the active language routes to Nemotron (set + non-English) and no model
    /// variant is on disk yet.
    private var needsCaptionModelConsent: Bool {
        guard let language = settings.activeEngineLanguageOrNil, language != "en" else { return false }
        return !nemotronModelDownloaded
    }

    /// Engine-specific terminology behaviour is deliberately explained next to
    /// the shared file picker: the two engines consume the same file but provide
    /// different levels of influence over recognition.
    static func vocabularyHelpText(for engine: TranscriptionEngineSetting) -> String {
        switch engine {
        case .parakeet:
            "Text file with one term per line. Parakeet uses CTC rescoring for saved transcription. "
                + "Live captions do not use CTC vocabulary rescoring."

        case .whisperKit:
            "Text file with one term per line. Enable the experimental custom vocabulary prompt to pass a "
                + "soft 32-token decoder hint to WhisperKit; it is not a guaranteed correction. "
                + "It applies to live captions only when they use "
                + "WhisperKit; language-specific live backends do not use it."
        }
    }

    static let whisperKitVocabularyPromptHelpText = "Experimental. WhisperKit treats the vocabulary as a decoder hint, "
        + "not a correction. In a dense four-speaker English evaluation, a 25-content-token prompt "
        + "from this 32-token budget raised word error rate from 29% to 77% and deletions from 73 to 241. "
        + "It can omit whole sentences. Results vary by audio; prefer Parakeet for vocabulary boosting."

    /// Whether any Nemotron multilingual model variant is already on disk.
    private var nemotronModelDownloaded: Bool {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask,
        ).first else { return false }
        let dir = base.appendingPathComponent("FluidAudio/Models/nemotron-multilingual")
        return FileManager.default.fileExists(atPath: dir.path)
    }

    /// Describes which low-latency backend the current transcription language
    /// selects. The backend follows the active engine's configured language (no
    /// toggle): English → Parakeet EOU, any other set language → Nemotron
    /// multilingual streaming, auto-detect → the standard re-transcribe engine.
    private var captionBackendFootnote: String {
        switch settings.activeEngineLanguageOrNil {
        case .none:
            "Caption backend follows your transcription language. Auto-detect uses the "
                + "standard re-transcribe engine; set a specific language for low-latency "
                + "streaming captions."

        case "en":
            "Caption backend follows your transcription language. English uses the "
                + "low-latency Parakeet streaming model."

        default:
            "Caption backend follows your transcription language. It uses the low-latency "
                + "Nemotron multilingual streaming model (~0.6-0.7 GB, downloads on first use)."
        }
    }

    private var liveTranscriptionFootnote: String {
        // Both current engines support the re-transcribe caption path, so
        // captions are always available; this just explains the overlay. If a
        // future engine returns `supportsLiveTranscription == false`, reintroduce
        // a conditional "unsupported" message gated on that + `englishStreaming`.
        "Captions appear in a click-through overlay at the bottom of "
            + "the screen during recording. Hold ⌥ (Option) to drag "
            + "it; the position is remembered across sessions. "
            + "Caption text is **not** logged by default — enable "
            + "\"Verbose Diagnostic Logging\" in Advanced to see "
            + "partials + finals in Console.app (subsystem "
            + "com.meetingtranscriber, category LiveTranscription). "
            + "Engine changes take effect on the next recording — "
            + "switching mid-recording is not supported."
    }

    private var activeEngine: any TranscribingEngine {
        switch settings.transcriptionEngine {
        case .parakeet: parakeetEngine
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

        case .unloaded:
            Button("Load Model") {
                if settings.transcriptionEngine == .whisperKit {
                    whisperKitEngine.modelVariant = settings.whisperKitModel
                }
                Task { await engine.loadModel() }
            }
        }
    }
}
