import Foundation

/// User-facing macOS System Settings navigation paths, kept in one place so the
/// tap-error hint, the permission UI, and the channel-health notification all
/// name the pane identically. macOS 15 (Sequoia) renamed the "Screen Recording"
/// pane to "Screen & System Audio Recording"; the app supports macOS 14.2+, so
/// the correct label depends on the running OS.
public enum SystemSettingsPaths {
    /// Path to the pane that gates screen capture and system-audio recording —
    /// the permission the CATapDescription process tap needs (or falls back to).
    /// Callers add their own lead-in / trailing action text.
    public static var screenRecording: String {
        let sequoiaOrLater = if #available(macOS 15, *) {
            true
        } else {
            false
        }
        return screenRecordingPath(sequoiaOrLater: sequoiaOrLater)
    }

    /// Pure form of ``screenRecording`` so both OS branches are unit-testable
    /// without faking the running OS version.
    static func screenRecordingPath(sequoiaOrLater: Bool) -> String {
        let pane = sequoiaOrLater ? "Screen & System Audio Recording" : "Screen Recording"
        return "System Settings → Privacy & Security → \(pane)"
    }
}
