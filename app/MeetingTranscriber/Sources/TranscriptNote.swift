import Foundation

/// Puts a recording-level annotation at the top of a transcript.
///
/// Called from one place, `[TimestampedSegment].transcriptText(note:)`, which
/// every transcript that reaches disk is rendered through. That is deliberate:
/// the transcript is rendered more than once (the mid-pipeline draft, the
/// speaker-labeled rewrite, and the late re-diarization's rebuild from cached
/// segments), and annotating at each point that *writes* one instead left the
/// draft without a note. Rendering composes the text fresh each time, so the
/// note lands exactly once by construction rather than by a guard.
enum TranscriptNote {
    /// - Parameters:
    ///   - note: The line to place first, or nil when the recording has
    ///     nothing to annotate. An empty string counts as nothing, so a caller
    ///     reading a blank field does not produce a transcript that opens with
    ///     an empty line.
    ///   - transcript: The transcript text as rendered.
    static func prepend(_ note: String?, to transcript: String) -> String {
        guard let note, !note.isEmpty else { return transcript }
        // An all-suppressed late rebuild genuinely renders empty, and a
        // trailing blank line on a note-only file would be noise.
        guard !transcript.isEmpty else { return note }
        // A blank line, because run together with the first utterance the note
        // reads as part of what someone said.
        return note + "\n\n" + transcript
    }
}
