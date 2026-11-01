import AudioTapLib
import Foundation

/// Short, plain-English explanations for settings options, surfaced via ``HelpBadge``.
///
/// Kept out of the view bodies so those stay lint- and type-check-friendly
/// (no inline string literals inflating SwiftUI expression type-checking), and
/// so the help copy is auditable in one place.
enum SettingsHelp {
    static let echoCancellation =
        """
        Removes the remote voices from the microphone audio with an on-device \
        model before it is transcribed. Because it works on the audio rather \
        than on the text, the cleaned track is also what speaker detection \
        sees.

        The saved recording is not changed: what is kept on disk stays the \
        audio your devices captured. Only runs on recordings already reported \
        as affected, and replaces the transcript option below wherever both \
        are on.
        """

    static let echoDedup =
        """
        When a meeting is held on loudspeakers, the microphone picks the remote \
        voices up as well and they are transcribed twice. With this on, the \
        second copy is left out of the transcript.

        Only applies to recordings already reported as affected, and only the \
        written transcript is shortened: nothing is removed from the recording.

        It is not exact, which is why it is off: a quiet remark you make while \
        the far end is talking can be taken for part of the echo and left out \
        of the transcript.
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

    static let silentTrackWatchdog =
        """
        When the app-audio track has carried only silence for \
        \(Int(SilentTrackWatchdogLimits.secondsOfZerosBeforeRebuild)) seconds, or has \
        delivered nothing at all since the capture started, while the \
        meeting app still reports playing audio, rebuild the capture, at most \
        once every \(Int(SilentTrackWatchdogLimits.secondsBetweenRebuilds)) seconds \
        and \(SilentTrackWatchdogLimits.rebuildsPerRecording) times per recording. \
        After \(SilentTrackWatchdogLimits.rebuildsWithoutSignal) rebuilds that do \
        not bring the audio back it stops, and tells you once your microphone \
        shows the call is live.

        Off by default because it is not yet known to help: each rebuild loses \
        at least half a second of audio, and a far end that is genuinely silent looks \
        the same. Every attempt is written to the diagnostic log, which is what \
        a report about a silent app track needs.
        """

    static let notionExport =
        """
        Sends each finished set of meeting notes (and the full transcript when it is \
        included) to a Notion database.

        Setup:
        1. In Notion, create an internal integration at notion.so/profile/\
        integrations and copy its token.
        2. Share the target page or database with that integration: open it in \
        Notion → "..." → "Connect to" → your integration. The integration only \
        sees content explicitly shared with it.
        3. Paste the token here and press "Test Connection".
        4. Choose an existing database, or create a "Meeting Transcriber" \
        database under one of your shared pages.
        5. Local Markdown backups are kept by default. Leave "Skip local markdown \
        file on success" off to keep all meeting notes locally.

        Only Title is required. Tags and Date are used when the database has a \
        recognized column; use "Add Optional Columns" to create them. If Notion \
        export fails, the local Markdown file is kept. The job finishes first and \
        the export runs in the background. If a request times \
        out while a page is being created, a retry can leave a second page in \
        the database.

        Speaker names are only added to Tags when "Include speaker names \
        as tags" is enabled. Re-exporting after speaker naming replaces \
        the exported page content, including text edited in Notion. \
        Sub-pages, databases, images and embeds added under the page are kept.
        """

    static let asymmetricSilenceWarning =
        "How long the condition must last before the indicator turns red and, for a channel " +
        "that has stopped delivering, before you are notified. Lower reacts faster to a dead " +
        "channel; higher ignores natural speaking pauses."
}
