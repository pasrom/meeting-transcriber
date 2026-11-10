import AppKit

extension Notification {
    /// The scene id the app opens the Settings window under.
    static let settingsWindowID = "settings"

    /// True for an `NSWindow.willCloseNotification` of the Settings window.
    /// Closing it only hides it, so neither a focus change nor `onDisappear`
    /// reaches its fields, and every window of the app posts this notification:
    /// the draft owners check for the Settings window here, in one place.
    var closesSettingsWindow: Bool {
        (object as? NSWindow)?.identifier?.rawValue == Self.settingsWindowID
    }
}
