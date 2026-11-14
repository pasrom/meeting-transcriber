import SwiftUI

/// Hoisted out of the menu-bar body, which has a type-check budget the analyze
/// build enforces.
extension AppState {
    /// Also what takes the mic-silent tint off the icon: silence is what the user asked for.
    var isMicMuted: Bool {
        watching.watchLoop?.isMicMuted ?? false
    }

    var micMuteToggle: (() -> Void)? {
        guard let loop = watching.watchLoop, loop.canMuteMic else { return nil }

        return { loop.toggleMicMute() }
    }

    var micMuteShortcut: KeyboardShortcut? {
        settings.micMuteHotkey?.menuShortcut
    }
}
