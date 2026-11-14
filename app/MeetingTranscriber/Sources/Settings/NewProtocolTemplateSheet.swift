// The New Template window that Settings → Output → Meeting Notes Templates opens
// as a sheet: a Name field, a note on what Create does, Cancel and Create. Its
// state and writes are the `ProtocolTemplatesModel`'s.

import SwiftUI

struct NewProtocolTemplateSheet: View {
    @Bindable var model: ProtocolTemplatesModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Template")
                .font(.headline)
            nameField
            note
            buttons
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Name")
                TextField("Name", text: $model.newTemplateName)
                    .labelsHidden()
                    .focused($nameFocused)
                    .accessibilityIdentifier(A11yID.protocolTemplateNewNameField)
            }
            if let problem = model.nameProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var note: some View {
        Label {
            Text(model.newTemplateNote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Escape and Return ride the buttons' shortcuts, which work whatever has
    /// the focus.
    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.cancelNewTemplate() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(A11yID.protocolTemplateNewCancelButton)
            Button("Create") { model.createTemplate() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
                .accessibilityIdentifier(A11yID.protocolTemplateNewCreateButton)
        }
    }
}
