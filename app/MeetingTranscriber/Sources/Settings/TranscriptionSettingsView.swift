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

                if settings.transcriptionEngine == .qwen3 {
                    Picker("Language", selection: $settings.qwen3Language) {
                        Text("Auto-detect").tag("")
                        ForEach(PickerLanguages.qwen3, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                }

                engineStatusView
            }
            .accessibilityIdentifier("transcriptionSection")
            .recordOnlyDisabled(settings.recordOnly)

            Section("Live transcription (PoC)") {
                Toggle("Show partial transcripts during recording", isOn: $settings.liveTranscriptionEnabled)
                    .disabled(!settings.transcriptionEngine.supportsLiveTranscription)

                Text(liveTranscriptionFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("liveTranscriptionSection")
            .recordOnlyDisabled(settings.recordOnly)
        }
        .formStyle(.grouped)
    }

    private var liveTranscriptionFootnote: String {
        if settings.transcriptionEngine.supportsLiveTranscription {
            "Captions appear in a click-through overlay at the bottom of "
                + "the screen during recording. Hold ⌥ (Option) to drag "
                + "it; the position is remembered across sessions. "
                + "Partials + finals are also logged to Console.app — "
                + "subsystem com.meetingtranscriber.app, category "
                + "LiveTranscription."
        } else {
            "This engine does not yet support live streaming. "
                + "Use WhisperKit or Parakeet."
        }
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
