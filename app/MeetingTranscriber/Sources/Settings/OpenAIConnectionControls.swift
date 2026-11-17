import SwiftUI

/// Connection picker with Add, Delete and Rename buttons at the top of the
/// OpenAI-compatible settings in Settings → Output. Each button asks first.
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

    /// Renames the connection the dialog named, only while it is still the selected one.
    func confirmRename() {
        let target = prompts.renaming
        prompts.renaming = nil
        let name = prompts.renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, target.id == settings.activeOpenAIConnectionID, !name.isEmpty else { return }
        settings.renameActiveOpenAIConnection(name)
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
        HStack {
            Picker("Connection", selection: Binding(
                get: { settings.activeOpenAIConnectionID },
                set: { id in switchConnection { settings.selectOpenAIConnection(id) } },
            )) {
                ForEach(settings.openAIConnections) { connection in
                    Text(connection.displayName).tag(connection.id)
                }
            }
            .accessibilityIdentifier(A11yID.openAIConnectionPicker)

            iconButton("Add Connection\u{2026}", systemImage: "plus", id: A11yID.openAIConnectionAddButton) {
                prompts.beginAdd(settings: settings)
            }

            iconButton("Delete Connection\u{2026}", systemImage: "minus", id: A11yID.openAIConnectionDeleteButton) {
                prompts.beginDelete(settings: settings)
            }
            .disabled(settings.openAIConnections.count <= 1)

            iconButton("Rename Connection\u{2026}", systemImage: "pencil", id: A11yID.openAIConnectionRenameButton) {
                prompts.beginRename(settings: settings)
            }
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
            "Rename Connection",
            isPresented: Binding(
                get: { prompts.renaming != nil },
                set: { if !$0 { prompts.renaming = nil } },
            ),
        ) {
            TextField("Name", text: $prompts.renameName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { confirmRename() }
                .disabled(!prompts.canRename)
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
    }

    private func iconButton(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}
