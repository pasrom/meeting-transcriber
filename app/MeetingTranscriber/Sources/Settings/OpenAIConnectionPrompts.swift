import Foundation
import Observation

/// The Add and Delete confirmation dialogs of `OpenAIConnectionControls`.
///
/// A reference type so a test holds the object the buttons write to (see
/// `docs/architecture/gui-testing.md`).
@Observable
@MainActor
final class OpenAIConnectionPrompts {
    var isAdding = false
    var newName = ""
    /// The connection the Delete dialog asks about; nil while it is closed.
    var deleting: OpenAIConnection?

    var canCreate: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func beginAdd(settings: AppSettings) {
        newName = settings.nextOpenAIConnectionName()
        isAdding = true
    }

    func beginDelete(settings: AppSettings) {
        deleting = settings.activeOpenAIConnection
    }
}
