import Foundation

/// Which remedy a dual-source recording gets for the loudspeaker coming back
/// through the microphone.
///
/// The two cannot compose, and `EchoCancelling`'s header says so as a
/// requirement on whoever lands the first consumer: cancellation removes the
/// far end from the microphone *audio*, the dedup drops microphone *transcript*
/// lines that duplicate the far end. Run together the dedup would be judging
/// audio the echo has already been taken out of, where its own measure (how
/// closely a microphone segment tracks the app track) no longer means what it
/// was calibrated to mean.
///
/// A named decision rather than an `if` at the call site, so the precedence is
/// written down once and a test can pin it. It is deliberately not a `Bool`
/// pair for the same reason `EchoVerdict` is not: three states, and collapsing
/// them loses the one that matters.
enum EchoRemedy: Equatable {
    /// Neither remedy is on. The transcript keeps both copies, which is what
    /// shipped before either existed. Not spelled `none`: as a `case` that
    /// name reads as `Optional.none` at every call site.
    case neither

    /// Acoustic cancellation on the microphone track before anything reads it.
    case cancellation

    /// Leave loudspeaker copies out of the merged transcript after the fact.
    case transcriptDedup

    /// What the settings ask for. Cancellation wins when both are on: it acts
    /// earlier and on the audio itself, so everything downstream of it
    /// (transcription, per-track diarization, the speaker embeddings taken from
    /// that diarization) sees a microphone track with the far end already gone.
    /// The dedup only ever reached the transcript, and could not keep a bled-in
    /// voice out of a stored speaker centroid.
    static func intended(cancellationEnabled: Bool, dedupEnabled: Bool) -> Self {
        if cancellationEnabled { return .cancellation }
        return dedupEnabled ? .transcriptDedup : .neither
    }

    /// What the recording actually got, which is not always what was asked for.
    ///
    /// The dedup stands down under cancellation for one reason: the far end is
    /// no longer in the audio its measure was calibrated on. When cancellation
    /// does not happen — no model, a throw, or a run that could not be shown to
    /// have removed anything — that reason is gone with it, the microphone
    /// track is exactly as it was recorded, and the fallback is valid again.
    ///
    /// Deciding this from the settings alone meant a user with both switches on
    /// and a missing model got neither remedy, on every affected recording,
    /// with one warning line as the only sign.
    static func applied(cancellationSucceeded: Bool, dedupEnabled: Bool) -> Self {
        if cancellationSucceeded { return .cancellation }
        return dedupEnabled ? .transcriptDedup : .neither
    }
}
