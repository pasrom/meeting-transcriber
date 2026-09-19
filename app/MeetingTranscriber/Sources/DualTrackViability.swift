import Foundation

/// Which tracks of a dual-source recording carry enough audio to transcribe.
///
/// A dual-source job used to hand both 16 kHz tracks to the engine with an
/// unguarded `try` each. An empty one threw `Invalid audio data provided. Must
/// be at least 300ms of 16kHz audio` out of the entire job, which discarded the
/// other track with it: ten minutes of a meeting lost to a microphone file that
/// held a WAV header and nothing else (issue #724, three field recordings).
///
/// Taken on track length rather than by catching that error. The error belongs
/// to one engine, and this repo ships two: the same empty file reaches
/// WhisperKit, which is under no obligation to fail the same way. A `try?`
/// would also swallow the failures that *should* end the job, a model that
/// could not load or a cancellation. A length says the one thing that is true
/// for every engine, that there is nothing here to transcribe, and it says it
/// before the work starts rather than after it failed.
///
/// A named decision rather than two `if`s in the stage, for the reason
/// `EchoRemedy` is one: the precedence is written down once, and the arms can
/// be pinned on a CI runner with no audio, no engine and no microphone.
enum DualTrackViability: Equatable, Sendable {
    /// Both tracks carry audio. What every healthy recording resolves to.
    case both

    /// Only the app track. The microphone delivered nothing: the field cases
    /// are a Bluetooth headset whose input never produced a buffer.
    case appOnly

    /// Only the microphone track. The mirror case, a solo meeting or a far end
    /// that never played.
    case micOnly

    /// Neither track has audio. The only case that still fails the job, because
    /// there is no transcript to save and nothing a warning could improve.
    case neither

    /// - Parameters:
    ///   - appFrames: Frames in the 16 kHz app track.
    ///   - micFrames: Frames in the 16 kHz microphone track.
    ///   - minimumFrames: The engine's own guard, `ASRConstants`'s 300 ms at
    ///     16 kHz. Passed in rather than read here so the threshold that
    ///     decides and the threshold that throws cannot drift apart silently,
    ///     and so the arms stay testable without FluidAudio.
    static func resolve(appFrames: Int, micFrames: Int, minimumFrames: Int) -> Self {
        // `>=`, not `>`: the engine accepts exactly its minimum, and a guard
        // that rejected what the engine would take would drop audio for no
        // reason.
        switch (appFrames >= minimumFrames, micFrames >= minimumFrames) {
        case (true, true): .both
        case (true, false): .appOnly
        case (false, true): .micOnly
        case (false, false): .neither
        }
    }

    /// What the job records about the track it dropped, or nil when nothing was
    /// dropped. `neither` carries none on purpose: that job fails, and its
    /// error is what the user sees.
    var droppedTrackWarning: String? {
        switch self {
        case .both, .neither: nil
        case .appOnly: "The microphone track had no audio — transcribed the app audio only"
        case .micOnly: "The app-audio track had no audio — transcribed the microphone only"
        }
    }

    /// One line prepended to the saved transcript, and with it to the text the
    /// protocol model is given.
    ///
    /// Without it a half recording is indistinguishable from a whole one: a
    /// transcript in which nobody ever speaks locally reads exactly like a
    /// meeting the user only listened to, and the model writes a protocol that
    /// looks complete. The job's warning cannot close that, because the model
    /// never sees it and it leaves with the job.
    ///
    /// Bracketed and on a single line so it cannot be mistaken for something a
    /// participant said. The prompt is not what makes it legible: a user's own
    /// `protocol_prompt.md` replaces the built-in one, so the line has to
    /// explain itself wherever it lands.
    var transcriptNote: String? {
        switch self {
        case .both, .neither: nil
        case .appOnly:
            "[Recording note: the microphone track was empty, so this transcript "
                + "contains only the other participants and nothing spoken locally.]"
        case .micOnly:
            "[Recording note: the app-audio track was empty, so this transcript "
                + "contains only what the microphone captured and nothing from the "
                + "other participants.]"
        }
    }
}
