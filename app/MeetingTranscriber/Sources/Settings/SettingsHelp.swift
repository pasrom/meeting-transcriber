import Foundation

/// Short, plain-English explanations for settings options, surfaced via ``HelpBadge``.
///
/// Kept out of the view bodies so those stay lint- and type-check-friendly
/// (no inline string literals inflating SwiftUI expression type-checking), and
/// so the help copy is auditable in one place.
enum SettingsHelp {
    static let echoDedup =
        """
        When a meeting is held on loudspeakers, the microphone picks the remote \
        voices up as well and they are transcribed twice. With this on, the \
        second copy is left out of the transcript.

        Only applies to recordings already reported as affected, and only the \
        written transcript is shortened: nothing is removed from the recording, \
        and a line is kept whenever anyone spoke over the far end.
        """

    static let vad =
        "Voice Activity Detection trims silent stretches out of the recording before " +
        "transcription, which speeds up processing and can improve accuracy. Enable it " +
        "for long or pause-heavy recordings; disable it if you notice speech being cut off."

    static let silentCaptureChannel =
        "Turns the menu bar red when one capture channel goes silent while the other " +
        "still carries audio, for example a muted microphone or a dropped app-audio tap. " +
        "You are notified only when a channel actually stops delivering audio, not when " +
        "it is merely quiet, so muting yourself is not reported as a fault. Turning this " +
        "off removes the colour, not the warnings: a channel that stops delivering is " +
        "still reported."

    static let asymmetricSilenceWarning =
        "How long the condition must last before the indicator turns red and, for a channel " +
        "that has stopped delivering, before you are notified. Lower reacts faster to a dead " +
        "channel; higher ignores natural speaking pauses."
}
