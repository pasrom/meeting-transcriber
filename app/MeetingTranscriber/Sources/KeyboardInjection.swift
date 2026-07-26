#if !APPSTORE
    import AppKit

    /// Types text into the app's own UI by posting real key events, backing
    /// `POST /ui/type`.
    ///
    /// Why posted events and not an accessibility set-value: writing
    /// `kAXValueAttribute` updates the control's accessibility value without going
    /// through `keyDown:` → `interpretKeyEvents:` → `insertText:`, so a SwiftUI
    /// `TextField`'s binding never observes it and the setting is never written.
    /// That is why the harness deliberately exposes no `/ui/setValue`. A posted key
    /// event travels the real responder chain, so the binding does update.
    /// `KeyboardInjectionTests` pins that behaviour.
    ///
    /// Delivery is `NSWindow.sendEvent` rather than `NSApp.postEvent` so it routes
    /// straight to the window's first responder and stays usable where `NSApp` is
    /// absent (the xctest process). The events never leave the process: no
    /// WindowServer HID path, hence no Accessibility/PostEvent TCC grant, and
    /// Secure Event Input cannot block them. Secure fields are out of scope by
    /// design — the `/ui/type` allowlist admits plain text fields only.
    @MainActor
    enum KeyboardInjection {
        /// Post one key-down/key-up pair carrying `characters` to `window`'s first
        /// responder.
        ///
        /// `keyCode` is left at 0 for every character: text insertion reads the
        /// event's `characters`, so a per-character virtual keycode would mean
        /// carrying a keyboard-layout table for no behavioural gain. Callers that
        /// need real key semantics (arrows, Tab, anything the responder switches on
        /// by code) must build those events with their proper keycodes instead.
        private static func post(
            characters: String, modifiers: NSEvent.ModifierFlags, in window: NSWindow,
        ) {
            for phase in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: phase,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: 0,
                ) else { continue }
                window.sendEvent(event)
            }
        }

        /// Type `text` into `window`'s first responder, one key pair per character.
        /// The caller focuses the target field first.
        static func type(_ text: String, into window: NSWindow) {
            for character in text {
                post(characters: String(character), modifiers: [], in: window)
            }
        }

        /// Select the focused field's contents, so a caller can replace them
        /// instead of appending at the cursor. Returns whether the responder
        /// accepted the action.
        ///
        /// Sends `selectAll:` down `window`'s own responder chain rather than
        /// posting Cmd-A. A command-modified key event is dispatched as a key
        /// EQUIVALENT: it resolves through the main menu against `NSApp.keyWindow`,
        /// so it silently does nothing when there is no matching menu item
        /// (measured: the field then appends instead of replacing) and can land in
        /// a different window when `window` is not key. The responder action is
        /// scoped to the window we were handed.
        static func selectAll(in window: NSWindow) -> Bool {
            window.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil) ?? false
        }

        /// Collapse the selection to the end of the field's contents.
        ///
        /// Required for a deterministic append: AppKit selects a text field's whole
        /// contents when it becomes first responder, so typing straight after a
        /// focus change REPLACES them. Without this the same request appends or
        /// replaces depending on whether the field happened to be focused already —
        /// measured, and the reason this is not left to the caller.
        static func moveToEnd(in window: NSWindow) -> Bool {
            window.firstResponder?
                .tryToPerform(#selector(NSResponder.moveToEndOfDocument(_:)), with: nil) ?? false
        }
    }
#endif
