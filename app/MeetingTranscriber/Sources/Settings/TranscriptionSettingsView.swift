import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionSettingsView: View {
    @Bindable var settings: AppSettings
    var whisperKitEngine: WhisperKitEngine
    var parakeetEngine: ParakeetEngine

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

                engineStatusView
            }
            .accessibilityIdentifier("transcriptionSection")
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
            // backends (German/English) route captions through an
            // engine-independent streaming session.
            Toggle("Show partial transcripts during recording", isOn: $settings.liveTranscriptionEnabled)

            Text(captionBackendFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(liveTranscriptionFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("liveTranscriptionSection")
        .recordOnlyDisabled(settings.recordOnly)
    }

    /// Describes which low-latency backend the current transcription language
    /// selects. The backend follows the active engine's configured language (no
    /// toggle): German/Spanish/French/Italian/Portuguese → Nemotron streaming,
    /// English → Parakeet EOU, else → the standard re-transcribe engine.
    private var captionBackendFootnote: String {
        let language = settings.activeEngineLanguageOrNil
        if let language, LiveCaptionsGate.nemotronLanguages.contains(language) {
            return "Caption backend follows your transcription language. German, Spanish, "
                + "French, Italian, and Portuguese use the low-latency Nemotron streaming "
                + "model (~611 MB, downloads on first use)."
        }
        if language == "en" {
            return "Caption backend follows your transcription language. English uses the "
                + "low-latency Parakeet streaming model."
        }
        return "Caption backend follows your transcription language. Set German, Spanish, "
            + "French, Italian, Portuguese, or English for low-latency streaming captions; "
            + "other languages (or auto-detect) use the standard re-transcribe engine."
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
            + "com.meetingtranscriber.app, category LiveTranscription). "
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
