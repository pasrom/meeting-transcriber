import Foundation
import Observation

/// The Add, Rename and Delete dialogs of `OpenAIConnectionControls`.
///
/// A reference type so a test holds the object the buttons write to (see
/// `docs/architecture/gui-testing.md`).
@Observable
@MainActor
final class OpenAIConnectionPrompts {
    var isAdding = false
    var newName = ""
    /// The connection the Rename dialog edits; nil while it is closed.
    var renaming: OpenAIConnection?
    var renameName = ""
    /// The connection the Delete dialog asks about; nil while it is closed.
    var deleting: OpenAIConnection?

    var canCreate: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRename: Bool {
        !renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func beginAdd(settings: AppSettings) {
        newName = settings.nextOpenAIConnectionName()
        isAdding = true
    }

    func beginRename(settings: AppSettings) {
        // The stored name, not `displayName`: a cleared name must not prefill the placeholder.
        renameName = settings.activeOpenAIConnection?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        renaming = settings.activeOpenAIConnection
    }

    func beginDelete(settings: AppSettings) {
        deleting = settings.activeOpenAIConnection
    }
}
