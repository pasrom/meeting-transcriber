import SwiftUI

/// The Storage section of the Transcription settings: WhisperKit models earlier
/// builds left in `Documents`. Its own section rather than part of
/// "Transcription": the leftovers matter whichever engine is picked, and
/// record-only mode, which dims that section, does not make them any smaller.
/// One checkbox per variant and nothing ticked up front: only the user can know
/// whether another app still uses a copy. Shown only while there is something
/// to remove or to explain.
struct LegacyWhisperModelsSection: View {
    let state: LegacyWhisperModelsState

    var body: some View {
        if state.isVisible {
            Section("Storage") {
                if !state.models.isEmpty {
                    Text(state.summary)
                    Text(LegacyWhisperModelInventory.sharedFolderNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    toggles
                    trashRow
                }
                if let scanProblem = state.scanProblem {
                    Text(scanProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let failureMessage = state.failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Addressed by row index, like the other per-row controls (`A11yID`).
    private var toggles: some View {
        ForEach(Array(state.models.enumerated()), id: \.element.variant) { index, model in
            Toggle(LegacyWhisperModelInventory.rowLabel(model), isOn: Binding(
                get: { state.isSelected(model.variant) },
                set: { state.setSelected(model.variant, $0) },
            ))
            .toggleStyle(.checkbox)
            .disabled(state.isRemoving)
            .accessibilityIdentifier(A11yID.legacyWhisperModelToggle(index))
        }
    }

    private var trashRow: some View {
        HStack {
            Spacer()
            Button("Move Selected to Trash\u{2026}") { state.isConfirming = true }
                .disabled(state.selection.isEmpty || state.isRemoving)
                .accessibilityIdentifier(A11yID.legacyWhisperModelsTrashButton)
        }
        .confirmationDialog("Move old models to the Trash?", isPresented: Bindable(state).isConfirming) {
            Button("Move to Trash", role: .destructive) {
                Task { await state.moveSelectedToTrash() }
            }
        } message: {
            Text(state.confirmationMessage)
        }
    }
}
