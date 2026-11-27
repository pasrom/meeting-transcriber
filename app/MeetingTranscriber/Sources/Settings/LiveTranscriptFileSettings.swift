import AppKit
import SwiftUI

/// Settings → Transcription rows for the live transcript file (`LiveTranscriptFile`):
/// the toggle, what writing it means, and a button that opens the folder. Nested
/// under live captions like the overlay toggle, and disabled while they are off,
/// because without captions there are no finals to write.
struct LiveTranscriptFileSettings: View {
    @Bindable var settings: AppSettings
    var directory: URL = AppPaths.liveTranscriptsDir
    /// Opens the folder in Finder. View tests replace it, so a tap opens no Finder window.
    var reveal: @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    static let footnote =
        "While a recording runs, its finalized captions are written as plain text to a "
            + "new JSON Lines file, so a local tool can follow the meeting. " + readersNote
            + " They are not deleted automatically."

    /// The App Store build keeps the files in its sandbox container, where macOS may
    /// ask before another app reads them; that prompt was not checked.
    #if APPSTORE
        private static let readersNote = "Other apps running under your user account may be able to read these files."
    #else
        private static let readersNote = "Any app running under your user account can read these files."
    #endif

    var body: some View {
        Toggle("Write live transcript to a file", isOn: $settings.liveTranscriptFileEnabled)
            .disabled(!settings.liveTranscriptionEnabled)
            .accessibilityIdentifier(A11yID.liveTranscriptFileToggle)
        Text(Self.footnote)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        // The folder appears with the first file; creating it here means the
        // button opens the folder even before that.
        Button("Open Live Transcripts Folder") {
            if LiveTranscriptFile.createDirectory(directory) { reveal(directory) }
        }
        .accessibilityIdentifier(A11yID.liveTranscriptFolderButton)
    }
}
