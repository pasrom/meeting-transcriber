import Foundation

@MainActor
extension WatchingController {
    func syncMicMuteHotkey() {
        guard watchLoop?.canMuteMic == true, let hotkey = settings.micMuteHotkey else {
            micMuteHotkeyRegistrar.unregister()
            return
        }
        let registered = micMuteHotkeyRegistrar.register(hotkey) { [weak self] in
            self?.watchLoop?.toggleMicMute()
        }
        if !registered {
            notifier.notify(
                title: "Mic Mute Shortcut Unavailable",
                body: "\(hotkey.displayName) is in use by another app. Use the menu bar to mute, or choose another shortcut in Settings.",
                urgency: .standard,
            )
        }
    }
}
