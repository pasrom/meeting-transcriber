import AppKit
import SwiftUI

/// The canonical terminology rows of the Vocabulary section. Its own file so
/// `TranscriptionSettingsView.swift` stays under the file-length limit.
extension TranscriptionSettingsView {
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

    private var terminologyRulesFileRow: some View {
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
    private var terminologyRulesSource: some View { // swiftlint:disable:this attributes
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
