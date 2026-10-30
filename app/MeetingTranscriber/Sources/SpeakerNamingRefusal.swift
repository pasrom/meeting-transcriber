import Foundation

/// Why the naming session did not take an answer from the naming dialog. The
/// dialog shows `message` and stays usable, instead of treating the answer as
/// given and going dead until it is reopened.
enum SpeakerNamingRefusal: Error, Equatable {
    /// The job is no longer waiting for names: a re-run or confirm for it is
    /// already under way, or it was cancelled or finished.
    case notAwaitingNaming
    /// A re-run needs the meeting's saved 16 kHz audio, and none of the folders
    /// the job wrote to holds it any more.
    case rerunAudioMissing
    /// A re-run needs a diarizer, and none is available right now.
    case rerunDiarizerUnavailable
    /// A re-run ran and failed; the dialog shows the naming it had before.
    case rerunFailed
    /// A re-run ran and found no voices it could name; the dialog shows the
    /// naming it had before.
    case rerunFoundNoVoices

    var message: String {
        switch self {
        case .notAwaitingNaming:
            "This meeting is no longer waiting for speaker names."

        case .rerunAudioMissing:
            "Re-run is not possible: the saved audio for this meeting was not found."

        case .rerunDiarizerUnavailable:
            "Re-run is not possible: speaker diarization is not available right now."

        case .rerunFailed:
            "Re-run failed, so the speakers from before are shown."

        case .rerunFoundNoVoices:
            "Re-run found no voices to name, so the speakers from before are shown."
        }
    }
}
