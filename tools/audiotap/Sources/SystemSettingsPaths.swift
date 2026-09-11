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

    /// Path to the pane that changes which device the system plays through.
    ///
    /// Named in the app-audio fault messages because switching the system
    /// output device is the one thing that rebuilds the tap, and a user told to
    /// switch it reaches for the picker in front of them, which during a call is
    /// the meeting app's own. That one cannot work: the rebuild is triggered by
    /// a change of the *system* default output device, which an output chosen
    /// inside another app does not touch.
    ///
    /// Unlike ``screenRecording`` this needs no OS branch. Output has lived
    /// inside the Sound pane since Ventura, and the app's floor is macOS 14.2.
    public static let soundOutput = "System Settings → Sound → Output"

    /// Pure form of ``screenRecording`` so both OS branches are unit-testable
    /// without faking the running OS version.
    static func screenRecordingPath(sequoiaOrLater: Bool) -> String {
        let pane = sequoiaOrLater ? "Screen & System Audio Recording" : "Screen Recording"
        return "System Settings → Privacy & Security → \(pane)"
    }
}
