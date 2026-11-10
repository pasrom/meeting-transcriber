import AppKit
import Foundation
import Observation

/// What is being typed into the meeting-notes API key fields, kept out of the
/// Keychain until a field commits (see `DraftTextField`).
///
/// Both keys are computed straight over the Keychain in `AppSettings`. Bound to
/// a field directly, every body evaluation was a Keychain read and every typed
/// character a Keychain write, and a half-typed key was what a job starting
/// meanwhile used. The keys are read once, when this object is made, and the
/// stored value the fields compare against is kept here.
///
/// `ObservableObject` only so `@StateObject` keeps one instance across view
/// re-creation: the parent re-creates the view on every settings change, and
/// the init reads the Keychain.
@Observable
@MainActor
final class ProtocolAPIKeyDrafts: ObservableObject {
    var openAI: String
    private(set) var savedOpenAI: String
    // Declared in both builds (unused in the App Store one) so the Observation
    // macro sees them as plain stored properties, not inside a `#if` block.
    var claude = ""
    private(set) var savedClaude = ""

    init(settings: AppSettings) {
        let openAIKey = settings.openAIAPIKey
        savedOpenAI = openAIKey
        openAI = openAIKey
        #if !APPSTORE
            let claudeKey = settings.claudeAPIKey
            savedClaude = claudeKey
            claude = claudeKey
        #endif
    }

    func commitOpenAI(_ key: String, to settings: AppSettings) {
        settings.openAIAPIKey = key
        // Read back, so a failed Keychain write does not show as saved.
        savedOpenAI = settings.openAIAPIKey
    }

    #if !APPSTORE
        func commitClaude(_ key: String, to settings: AppSettings) {
            settings.claudeAPIKey = key
            savedClaude = settings.claudeAPIKey
        }
    #endif

    /// Hand over every edit a field has not committed yet. Both drafts start
    /// from the stored keys, so a draft whose field is not shown is unchanged
    /// and writes nothing.
    func commitPending(to settings: AppSettings) {
        if openAI != savedOpenAI { commitOpenAI(openAI, to: settings) }
        #if !APPSTORE
            if claude != savedClaude { commitClaude(claude, to: settings) }
        #endif
    }

    /// Closing the Settings window only hides it, so neither a focus change nor
    /// `onDisappear` reaches the fields.
    func settingsWindowWillClose(_ notification: Notification, settings: AppSettings) {
        guard notification.closesSettingsWindow else { return }
        commitPending(to: settings)
    }
}
