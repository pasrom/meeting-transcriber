import Foundation

/// What the snapshot restore should do with a job it found mid-run.
enum ProtocolResumeDisposition: Equatable {
    /// Run the pipeline from the top.
    case fullRun
    /// Generate the protocol from the transcript already on disk.
    case resumeProtocolOnly
    /// Everything was written; only the terminal transition is missing.
    case finish
}

/// Decides whether a restored job can skip straight to protocol generation
/// instead of re-transcribing and re-diarizing for a result it already has.
enum ProtocolResumePolicy {
    /// - Parameters:
    ///   - interruptedIn: the state the job carried in the snapshot, before the
    ///     restore reset it to `.waiting`. Keying on "a transcript exists"
    ///     instead would be wrong: stage 1 writes a draft, so a job killed
    ///     during diarization has one without speaker labels, and resuming from
    ///     it would publish that draft as the finished transcript.
    ///   - namingDataOnDisk: a confirm drops its naming data the moment it has
    ///     rewritten the transcript, and the hop into `.generatingProtocol`
    ///     ahead of that is synchronous, so finding the sidecar means the
    ///     rewrite did not happen. Resuming there would publish the auto-names
    ///     and silently discard what the user had just confirmed; a full run
    ///     parks the job back in the dialog and asks again, which is what
    ///     happened before this policy existed.
    ///   - transcriptExists: checked against the filesystem, not merely a
    ///     non-nil path.
    ///   - hasNamingSlug: without it `generateProtocol` falls back to a freshly
    ///     stamped stem, and the `.md` would no longer match the `.txt` and the
    ///     audio of the same meeting.
    ///   - protocolExists: also a real check. A path alone would let `.finish`
    ///     complete a job whose `.md` has since been deleted, reporting success
    ///     with nothing to show, and the terminal transition would then remove
    ///     the transcript too when separate raw output is off.
    static func decide(
        interruptedIn state: JobState,
        namingDataOnDisk: Bool,
        transcriptExists: Bool,
        hasNamingSlug: Bool,
        protocolExists: Bool,
    ) -> ProtocolResumeDisposition {
        guard state == .generatingProtocol, !namingDataOnDisk else { return .fullRun }
        if protocolExists { return .finish }
        guard transcriptExists, hasNamingSlug else { return .fullRun }
        return .resumeProtocolOnly
    }
}
