import SwiftUI

/// Connection picker, name field and Add/Delete buttons above the
/// OpenAI-compatible fields in Settings → Meeting Notes. Add and Delete each
/// ask first.
struct OpenAIConnectionControls: View {
    @Bindable var settings: AppSettings
    /// Runs a change of the selected connection; the parent hands the key
    /// draft over around it.
    let switchConnection: (() -> Void) -> Void
    @State private var prompts: OpenAIConnectionPrompts

    init(
        settings: AppSettings,
        prompts: OpenAIConnectionPrompts = OpenAIConnectionPrompts(),
        switchConnection: @escaping (() -> Void) -> Void,
    ) {
        self.settings = settings
        self.switchConnection = switchConnection
        _prompts = State(initialValue: prompts)
    }

    func confirmAdd() {
        let name = prompts.newName.trimmingCharacters(in: .whitespacesAndNewlines)
        prompts.isAdding = false
        guard !name.isEmpty else { return }
        switchConnection { settings.addOpenAIConnection(named: name) }
    }

    /// Deletes the connection the dialog named, only while it is still the selected one.
    func confirmDelete() {
        let target = prompts.deleting
        prompts.deleting = nil
        guard let target, target.id == settings.activeOpenAIConnectionID else { return }
        switchConnection { settings.deleteActiveOpenAIConnection() }
    }

    var body: some View {
        // Read here so this body observes the selection: the bindings' getters
        // run outside it (see `DraftTextField`).
        let _ = settings.activeOpenAIConnectionID // swiftlint:disable:this redundant_discardable_let
        Picker("Connection", selection: Binding(
            get: { settings.activeOpenAIConnectionID },
            set: { id in switchConnection { settings.selectOpenAIConnection(id) } },
        )) {
            ForEach(settings.openAIConnections) { connection in
                Text(connection.displayName).tag(connection.id)
            }
        }
        .accessibilityIdentifier(A11yID.openAIConnectionPicker)

        HStack {
            Text("Connection Name")
            Spacer()
            TextField("", text: Binding(
                get: { settings.activeOpenAIConnection?.name ?? "" },
                set: { settings.renameActiveOpenAIConnection($0) },
            ))
            .frame(width: 200)
            .multilineTextAlignment(.trailing)
            .accessibilityIdentifier(A11yID.openAIConnectionNameField)
        }

        HStack {
            Button("Add Connection\u{2026}") {
                prompts.beginAdd(settings: settings)
            }
            .accessibilityIdentifier(A11yID.openAIConnectionAddButton)

            Button("Delete Connection\u{2026}") {
                prompts.beginDelete(settings: settings)
            }
            .disabled(settings.openAIConnections.count <= 1)
            .accessibilityIdentifier(A11yID.openAIConnectionDeleteButton)

            Spacer()
        }
        .alert("Add Connection", isPresented: $prompts.isAdding) {
            TextField("Name", text: $prompts.newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { confirmAdd() }
                .disabled(!prompts.canCreate)
        } message: {
            Text("Copies the current endpoint, model and settings. The new connection starts with no API key.")
        }
        .alert(
            "Delete \u{201C}\(prompts.deleting?.displayName ?? "")\u{201D}?",
            isPresented: Binding(
                get: { prompts.deleting != nil },
                set: { if !$0 { prompts.deleting = nil } },
            ),
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its settings are removed and its API key is deleted from the Keychain. This cannot be undone.")
        }
        Text("Each connection keeps its own endpoint, model and API key. Meeting notes use the selected one.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
