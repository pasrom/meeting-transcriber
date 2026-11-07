import AppKit
import Carbon.HIToolbox
import os.log
import SwiftUI

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "GlobalHotkey")

/// A key combination that works while another app is frontmost.
struct GlobalHotkey: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// As typed, for example "⌃⌥M". Stored because a key code alone cannot be
    /// named without the keyboard layout that produced it.
    let displayName: String

    /// Nil unless Command, Control or Option is held: anything less would swallow
    /// ordinary typing in every app for the length of a recording.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
        guard !modifiers.isDisjoint(with: [.command, .control, .option]),
              let characters, !characters.isEmpty else { return nil }

        var carbon: UInt32 = 0
        var name = ""
        if modifiers.contains(.control) { carbon |= UInt32(controlKey); name += "⌃" }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey); name += "⌥" }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey); name += "⇧" }
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey); name += "⌘" }
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = carbon
        self.displayName = name + characters.uppercased()
    }
}

extension GlobalHotkey {
    /// The same combination as a menu item shows it. Lowercase, because a menu
    /// reads an uppercase key equivalent as also needing Shift.
    var menuShortcut: KeyboardShortcut? {
        guard let key = displayName.last?.lowercased().first else { return nil }

        var modifiers: SwiftUI.EventModifiers = []
        if carbonModifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
    }
}

/// Holds at most one registered `GlobalHotkey`. Carbon's API, because it needs no
/// permission: an `NSEvent` global monitor would need the Accessibility grant.
@MainActor
final class GlobalHotkeyRegistrar {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    /// False when the system refused, usually because another app holds the
    /// combination.
    @discardableResult
    func register(_ hotkey: GlobalHotkey, action: @escaping () -> Void) -> Bool {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed),
        )
        let installed = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, context -> OSStatus in
                guard let context else { return OSStatus(eventNotHandledErr) }

                let registrar = Unmanaged<GlobalHotkeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                // Carbon delivers on the main thread's event loop.
                MainActor.assumeIsolated { registrar.action?() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef,
        )
        // "MTMM": this app's signature for the one hotkey it registers.
        let id = EventHotKeyID(signature: 0x4D54_4D4D, id: 1)
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.carbonModifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef,
        )
        guard installed == noErr, status == noErr else {
            logger.warning("Hotkey registration refused: handler=\(installed) key=\(status)")
            unregister()
            return false
        }
        self.action = action
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        action = nil
    }
}
