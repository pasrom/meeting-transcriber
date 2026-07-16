import Foundation

/// Short, plain-English explanations for settings options, surfaced via ``HelpBadge``.
///
/// Kept out of the view bodies so those stay lint- and type-check-friendly
/// (no inline string literals inflating SwiftUI expression type-checking), and
/// so the help copy is auditable in one place.
enum SettingsHelp {
    static let vad =
        "Voice Activity Detection trims silent stretches out of the recording before " +
        "transcription, which speeds up processing and can improve accuracy. Enable it " +
        "for long or pause-heavy recordings; disable it if you notice speech being cut off."

    static let silentCaptureChannel =
        "Turns the menu bar red when one capture channel goes silent while the other " +
        "still carries audio, for example a muted microphone or a dropped app-audio tap. " +
        "It catches these one-sided capture failures live, during a meeting."

    static let asymmetricSilenceWarning =
        "How long one channel must stay silent, while the other keeps producing audio, " +
        "before the indicator and notification fire. Lower reacts faster to a dead channel; " +
        "higher ignores natural speaking pauses."
}
