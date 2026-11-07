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
            "Works from any app while a recording runs. Must include ⌘, ⌃ or ⌥; standard app and macOS shortcuts are refused. Applies from the next recording.",
        )
        .onDisappear { stopCapturing() }
    }

    private func startCapturing() {
        isCapturing = true
        conflict = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels. A combination with no modifier is ignored, so keep
            // listening rather than letting it type into the window.
            if event.keyCode != 53 {
                guard let captured = GlobalHotkey(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags,
                    characters: event.charactersIgnoringModifiers,
                ) else { return nil }

                conflict = captured.conflict(with: systemShortcuts())
                if conflict == nil { hotkey = captured }
            }
            stopCapturing()
            return nil
        }
    }

    private func stopCapturing() {
        isCapturing = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
