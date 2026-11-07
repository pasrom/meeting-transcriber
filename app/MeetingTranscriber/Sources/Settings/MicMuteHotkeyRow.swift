import AppKit
import SwiftUI

/// Settings row that captures the shortcut toggling the mic mute during a recording.
struct MicMuteHotkeyRow: View {
    @Binding var hotkey: GlobalHotkey?
    /// Read at each capture, so a shortcut turned off in System Settings meanwhile is allowed.
    var systemShortcuts: () -> [SystemShortcut] = GlobalHotkey.enabledSystemShortcuts
    @State private var isCapturing = false
    @State private var monitor: Any?
    /// Why the last typed combination was refused; the previous shortcut stays.
    @State private var conflict: String?

    private var buttonTitle: String {
        if isCapturing { return "Type Shortcut…" }
        return hotkey?.displayName ?? "Set Shortcut"
    }

    var body: some View {
        Group {
            LabeledContent("Mute Mic Shortcut") {
                HStack {
                    Button(buttonTitle) {
                        isCapturing ? stopCapturing() : startCapturing()
                    }
                    .accessibilityIdentifier(A11yID.micMuteHotkeyButton)

                    if hotkey != nil, !isCapturing {
                        Button("Clear") {
                            hotkey = nil
                            conflict = nil
                        }
                    }
                }
            }
            if let conflict {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(A11yID.micMuteHotkeyConflict)
            }
        }
        .help(
            "Works from any app while a recording runs. Needs two of ⌘, ⌃ and ⌥, one with a function key, or F13 to F20 alone; "
                + "common app and macOS shortcuts are refused. Applies from the next recording.",
        )
        .onDisappear { stopCapturing() }
    }

    private func startCapturing() {
        isCapturing = true
        conflict = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Self.capture(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                // Without Shift, so ⇧⌘4 is named by its key and not by "$".
                characters: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
                systemShortcuts: systemShortcuts,
            ) {
            case .keepListening: return nil
            case .cancel: break
            case let .refuse(reason): conflict = reason
            case let .accept(captured): hotkey = captured
            }
            stopCapturing()
            return nil
        }
    }

    enum CaptureOutcome: Equatable {
        case keepListening, cancel
        case refuse(String)
        case accept(GlobalHotkey)
    }

    /// What one key press does while capturing, apart from the event monitor so a test can drive it.
    static func capture(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?,
        systemShortcuts: () -> [SystemShortcut],
    ) -> CaptureOutcome {
        // Escape cancels. A combination with no modifier is ignored, so keep
        // listening rather than letting it type into the window.
        if keyCode == 53 { return .cancel }
        guard let captured = GlobalHotkey(keyCode: keyCode, modifiers: modifiers, characters: characters) else {
            return .keepListening
        }

        if let reason = captured.conflict(with: systemShortcuts()) { return .refuse(reason) }
        return .accept(captured)
    }

    private func stopCapturing() {
        isCapturing = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
