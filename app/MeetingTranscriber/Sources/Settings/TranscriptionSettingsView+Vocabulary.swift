import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension TranscriptionSettingsView {
    var vocabularySection: some View {
        Section("Vocabulary") {
            if settings.transcriptionEngine == .gigaAM {
                Text(Self.vocabularyHelpText(for: .gigaAM))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                customVocabularyToggle
                customVocabularyFileRows
            }
            terminologyRulesEditor
        }
        .accessibilityIdentifier(A11yID.vocabularySection)
        .recordOnlyDisabled(settings.recordOnly)
    }

    /// WhisperKit's help adds the experimental warning: it is the engine where the
    /// vocabulary can cost completeness.
    private var customVocabularyToggle: some View {
        HelpfulToggle(
            title: "Use custom vocabulary",
            help: settings.transcriptionEngine == .whisperKit
                ? SettingsHelp.customVocabularyWhisperKit
                : SettingsHelp.customVocabulary,
            isOn: $settings.customVocabularyEnabled,
        )
        .accessibilityIdentifier(A11yID.customVocabularyToggle)
    }

    /// Hidden while the switch is off, since no engine reads the file then.
    @ViewBuilder private var customVocabularyFileRows: some View {
        if settings.customVocabularyEnabled {
            customVocabularyRow
            customVocabularyValidation
        }
    }

    private var customVocabularyRow: some View {
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
    }

    private var customVocabularyValidation: some View {
        Text(settings.customVocabularyValidation.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear { settings.refreshCustomVocabularyValidation() }
            .onChange(of: settings.customVocabularyPath) { _, _ in
                settings.refreshCustomVocabularyValidation()
            }
    }
}

// MARK: - Terminology rules

private extension TranscriptionSettingsView {
    var terminologyRulesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Canonical terminology")
            terminologyRulesFileRow
            terminologyRulesSource
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
                .onAppear { settings.refreshTerminologyRulesValidation() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    settings.refreshTerminologyRulesValidation()
                }
        }
    }

    var terminologyRulesFileRow: some View {
        HStack {
            TextField("Terminology rules file (optional)", text: Binding(
                get: { settings.terminologyRulesFilePath },
                set: { settings.setTerminologyRulesFilePath($0) },
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(A11yID.terminologyRulesFilePathField)
            Button("Choose\u{2026}") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.plainText]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    settings.setTerminologyRulesFile(url)
                }
            }
        }
        .help("When a file is set, its rules are used instead of the text area and are read again at the start of each job.")
    }

    /// The text area while no rules file is set; otherwise the file's contents,
    /// read-only, as of the last read: on appearing, on a change of path, when
    /// the app becomes active and at each job start.
    @ViewBuilder
    var terminologyRulesSource: some View { // swiftlint:disable:this attributes
        if settings.usesTerminologyRulesFile {
            ScrollView {
                Text(settings.terminologyRulesFileContents)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 72)
            .accessibilityIdentifier(A11yID.terminologyRulesFilePreview)
        } else {
            TextEditor(text: $settings.terminologyRulesText)
                .font(.body.monospaced())
                .frame(minHeight: 72)
                .accessibilityIdentifier(A11yID.terminologyRulesEditor)
        }
    }
}
