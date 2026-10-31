import AppKit
import SwiftUI

/// Settings row that captures the shortcut toggling the mic mute during a recording.
struct MicMuteHotkeyRow: View {
    @Binding var hotkey: GlobalHotkey?
    @State private var isCapturing = false
    @State private var monitor: Any?

    private var buttonTitle: String {
        if isCapturing { return "Type Shortcut…" }
        return hotkey?.displayName ?? "Set Shortcut"
    }

    var body: some View {
        LabeledContent("Mute Mic Shortcut") {
            HStack {
                Button(buttonTitle) {
                    isCapturing ? stopCapturing() : startCapturing()
                }
                .accessibilityIdentifier(A11yID.micMuteHotkeyButton)

                if hotkey != nil, !isCapturing {
                    Button("Clear") { hotkey = nil }
                }
            }
        }
        .help("Works from any app while a recording runs. Must include ⌘, ⌃ or ⌥. Changes apply from the next recording.")
        .onDisappear { stopCapturing() }
    }

    private func startCapturing() {
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels. A combination with no modifier is refused, so
            // keep listening rather than letting it type into the window.
            if event.keyCode != 53, let captured = GlobalHotkey(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                characters: event.charactersIgnoringModifiers,
            ) {
                hotkey = captured
            } else if event.keyCode != 53 {
                return nil
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
