import Foundation

/// Puts a recording-level annotation at the top of a transcript.
///
/// The transcript is written out more than once and rebuilt in between:
/// diarization replaces it with the speaker-labeled rendering, and a late
/// re-diarization renders it again from the cached segments and writes that
/// over the saved file. An annotation prepended where the transcript is first
/// composed does not survive either. So the note is carried on the job and
/// applied at each point that writes a transcript out, which is why applying
/// it twice to the same text has to be harmless.
enum TranscriptNote {
    /// - Parameters:
    ///   - note: The line to place first, or nil when the recording has
    ///     nothing to annotate. An empty string counts as nothing, so a caller
    ///     reading a blank field does not produce a transcript that opens with
    ///     an empty line.
    ///   - transcript: The transcript text as rendered.
    static func prepend(_ note: String?, to transcript: String) -> String {
        guard let note, !note.isEmpty else { return transcript }
        guard !transcript.hasPrefix(note) else { return transcript }
        guard !transcript.isEmpty else { return note }
        // A blank line, because run together with the first utterance the note
        // reads as part of what someone said.
        return note + "\n\n" + transcript
    }
}
