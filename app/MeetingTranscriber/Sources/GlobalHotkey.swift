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

    /// F1 to F20 in order. By key code, because arrows, Home and End carry the
    /// `.function` flag too.
    static let functionKeyCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].map(UInt32.init)

    /// F13 to F20 have no job of their own on a Mac keyboard, so they need no modifier.
    static let spareFunctionKeyCodes = Set(functionKeyCodes.suffix(8))

    /// Common two-modifier shortcuts of macOS and its apps (hide others, minimise
    /// all, close all, inspector, full screen, lock screen, emoji picker), each
    /// as its key on the keyboard layout and its Carbon modifiers. A Carbon
    /// hotkey pre-empts them in every app.
    static let reservedShortcuts: [(key: String, carbonModifiers: UInt32)] = [
        ("h", optionKey | cmdKey), ("m", optionKey | cmdKey), ("w", optionKey | cmdKey), ("i", optionKey | cmdKey),
        ("f", controlKey | cmdKey), ("q", controlKey | cmdKey), (" ", controlKey | cmdKey),
    ].map { ($0.0, UInt32($0.1)) }

    /// Nil unless Command, Control or Option is held, or the key is F13 to F20,
    /// so plain typing is never taken as a shortcut. `conflict(with:)` holds the
    /// stricter rules.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
        guard !modifiers.isDisjoint(with: [.command, .control, .option]) || Self.spareFunctionKeyCodes.contains(UInt32(keyCode)),
              let characters, !characters.isEmpty else { return nil }

        var carbon: UInt32 = 0
        var name = ""
        if modifiers.contains(.control) { carbon |= UInt32(controlKey); name += "⌃" }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey); name += "⌥" }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey); name += "⇧" }
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey); name += "⌘" }
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = carbon
        // Uppercasing can lengthen ("ß" to "SS"); the last character names the key.
        let upper = characters.uppercased()
        if let index = Self.functionKeyCodes.firstIndex(of: UInt32(keyCode)) {
            self.displayName = name + "F\(index + 1)"
        } else {
            self.displayName = name + (upper.count == 1 ? upper : characters)
        }
    }
}

/// A system shortcut as `CopySymbolicHotKeys` reports it, with Carbon modifiers.
struct SystemShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
}

extension GlobalHotkey {
    private static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    /// Why this combination cannot be the mute shortcut, or nil when it can.
    ///
    /// Only what can be known is checked. Registration is not refused when
    /// another app holds the combination (measured with two processes: both
    /// register it, and `kEventHotKeyExclusive` is refused only when the other
    /// process asked for it too), and another app's menu shortcuts are not
    /// visible without the Accessibility grant, so neither is caught here.
    ///
    /// `layoutKey` names a key code on the keyboard layout in use, which is
    /// where a shortcut's letter sits: ⌃⌘Q is the key that types "a" on an
    /// ANSI keyboard set to AZERTY.
    func conflict(
        with systemShortcuts: [SystemShortcut], layoutKey: (UInt32) -> String? = GlobalHotkey.layoutKey,
    ) -> String? {
        if systemShortcuts.contains(where: matches) {
            return "This is a macOS shortcut. Choose another, or turn it off in System Settings → Keyboard → Keyboard Shortcuts."
        }
        let key = layoutKey(keyCode)
        if Self.reservedShortcuts.contains(where: { $0.key == key && $0.carbonModifiers == carbonModifiers & Self.modifierMask }) {
            return "This is a common app shortcut, which every app would lose during recordings. Choose another."
        }
        // One of ⌘, ⌃ or ⌥ with a key is what apps bind and what types symbols
        // (⌘C, ⇧⌘M, ⌃C in a terminal, ⌥L on a German layout). Function keys type
        // nothing.
        let held = [cmdKey, controlKey, optionKey].count { carbonModifiers & UInt32($0) != 0 }
        if held < 2, !Self.functionKeyCodes.contains(keyCode) {
            return "Apps use shortcuts like this one and would lose it during recordings. Hold two of ⌘, ⌃ and ⌥, or use a function key."
        }
        return nil
    }

    /// What the key types with no modifier on the layout shortcuts are read
    /// from: the current one, or its Latin stand-in for a layout such as
    /// Russian. Nil when the system does not say.
    static func layoutKey(forKeyCode keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }

        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var typed = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(
                bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(truncatingIfNeeded: keyCode),
                UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeys, typed.count, &length, &typed,
            )
        }
        guard status == noErr, length > 0 else { return nil }

        return String(utf16CodeUnits: typed, count: length).lowercased()
    }

    private func matches(_ shortcut: SystemShortcut) -> Bool {
        shortcut.keyCode == keyCode && shortcut.carbonModifiers & Self.modifierMask == carbonModifiers & Self.modifierMask
    }

    /// The enabled system shortcuts (Spotlight, screenshots, Mission Control and
    /// so on). Empty when the system does not say.
    static func enabledSystemShortcuts() -> [SystemShortcut] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return [] }

        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }

            return SystemShortcut(keyCode: UInt32(truncatingIfNeeded: code), carbonModifiers: UInt32(truncatingIfNeeded: modifiers))
        }
    }
}

extension GlobalHotkey {
    /// The same combination as a menu item shows it. Lowercase, because a menu
    /// reads an uppercase key equivalent as also needing Shift.
    var menuShortcut: KeyboardShortcut? {
        let functionKey = Self.functionKeyCodes.firstIndex(of: keyCode)
            .flatMap { UnicodeScalar(NSF1FunctionKey + $0) }.map(Character.init)
        guard let key = functionKey ?? displayName.last?.lowercased().first else { return nil }

        var modifiers: SwiftUI.EventModifiers = []
        if carbonModifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
    }
}

extension GlobalHotkey {
    /// "MTMM": this app's signature for the one hotkey it registers.
    static let carbonSignature: OSType = 0x4D54_4D4D
    static let carbonID: UInt32 = 1
}

/// What `WatchingController` needs of a registrar, so a test can stand in for Carbon.
@MainActor
protocol HotkeyRegistering: AnyObject {
    /// False when the system refused the combination.
    @discardableResult
    func register(_ hotkey: GlobalHotkey, action: @escaping () -> Void) -> Bool
    func unregister()
}

/// Holds at most one registered `GlobalHotkey`. Carbon's API, because it needs no
/// permission: an `NSEvent` global monitor would need the Accessibility grant.
@MainActor
final class GlobalHotkeyRegistrar: HotkeyRegistering {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    /// False when the system refused the combination. Another app holding it is
    /// not such a case; see `GlobalHotkey.conflict(with:)`.
    @discardableResult
    func register(_ hotkey: GlobalHotkey, action: @escaping () -> Void) -> Bool {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed),
        )
        let installed = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, context -> OSStatus in
                var pressed = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed,
                )
                // Every hotkey press in the process arrives here; only this registration's is ours.
                guard let context, read == noErr, pressed.signature == GlobalHotkey.carbonSignature,
                      pressed.id == GlobalHotkey.carbonID else { return OSStatus(eventNotHandledErr) }

                let registrar = Unmanaged<GlobalHotkeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                // Carbon delivers on the main thread's event loop.
                MainActor.assumeIsolated { registrar.action?() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef,
        )
        let id = EventHotKeyID(signature: GlobalHotkey.carbonSignature, id: GlobalHotkey.carbonID)
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
