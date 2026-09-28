import AppKit
import Foundation

/// What is being typed into the custom WhisperKit model fields, kept out of
/// `AppSettings` until a field commits (see `DraftTextField`).
///
/// One object rather than three `@State` strings, for the reason given on
/// `SpeakerNamingRowState`: a `@State` write from a view test is lost, so only an
/// object lets a test see the drafts the fields write to and "Load Model" reads.
/// The folder buttons go through it as well, to reset the folder draft.
@MainActor
@Observable
final class WhisperKitCustomModelDrafts {
    var repo = ""
    var variant = ""
    var folder = ""

    /// Hand over every edit a field has not committed yet, as that field would
    /// on Return. For "Load Model", which reads the selection from the settings:
    /// clicking it need not take focus from the field being edited.
    ///
    /// Only while WhisperKit is selected and the custom model is on, which is when
    /// the fields are shown and their drafts were filled from the settings.
    /// Otherwise a draft can still be empty, and handing it over would erase the
    /// setting.
    func commitPending(to settings: AppSettings) {
        guard settings.transcriptionEngine == .whisperKit, settings.whisperKitCustomModelEnabled else { return }
        if repo != settings.whisperKitCustomRepo { settings.whisperKitCustomRepo = repo }
        if variant != settings.whisperKitCustomVariant { settings.whisperKitCustomVariant = variant }
        if folder != settings.whisperKitCustomModelFolderPath { settings.setWhisperKitCustomModelFolderPath(folder) }
    }

    /// The scene id the app opens the Settings window under.
    static let settingsWindowID = "settings"

    /// Closing the Settings window only hides it, so neither a focus change nor
    /// `onDisappear` reaches the fields, and a value typed but never confirmed
    /// would stay in the field while the settings kept the old one. Every window
    /// of the app posts this notification, hence the check for the Settings window.
    func settingsWindowWillClose(_ notification: Notification, settings: AppSettings) {
        guard (notification.object as? NSWindow)?.identifier?.rawValue == Self.settingsWindowID else { return }
        commitPending(to: settings)
    }

    /// A folder picked with Choose. The draft is reset even when the path is the
    /// one already set: the field resets itself only when the setting changes, so
    /// after picking the same folder again an older edit would stay in the field
    /// and the next focus loss would commit it, dropping the bookmark just made.
    func chooseFolder(_ url: URL, in settings: AppSettings) {
        settings.setWhisperKitCustomModelFolder(url)
        folder = settings.whisperKitCustomModelFolderPath
    }

    /// Clear, with the folder draft reset in the same step. Clearing always changes
    /// the setting, so the field would also reset itself; this keeps the draft in
    /// step without depending on that.
    func clearFolder(in settings: AppSettings) {
        settings.clearWhisperKitCustomModelFolder()
        folder = settings.whisperKitCustomModelFolderPath
    }
}
