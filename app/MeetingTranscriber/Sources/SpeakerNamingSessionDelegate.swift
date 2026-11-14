import AudioTapLib
import Foundation

/// Collaborator that `PipelineQueue` calls for whatever it still owns while the
/// naming session runs. Strictly id-based (never index-based): a job index goes
/// stale across an `await` when another finished job is evicted by
/// `completedJobLifetime`, a documented past bug — so the session only ever
/// addresses a job by its `UUID`. The queue owns the session strongly
/// (`let naming`); the session holds this delegate weakly at rest (no retain
/// cycle) but captures it strongly per async flow, so an in-flight naming flow
/// keeps the queue alive to completion while a flow started against an
/// already-gone queue no-ops harmlessly. See `SpeakerNamingSession.delegate`.
@MainActor
protocol SpeakerNamingSessionDelegate: AnyObject {
    /// A value copy of the job, or nil if it is no longer tracked.
    func job(withID id: UUID) -> PipelineJob?
    func updateJobState(id: UUID, to newState: JobState, error: String?)
    func finishWithAcceptedAutoNames(jobID: UUID)
    func addWarning(id: UUID, _ message: String)
    /// Persist the per-job naming metadata on the (queue-owned) job. `nil`
    /// for either field means "leave unchanged".
    /// `wroteSidecarsIn` records a folder as holding this job's sidecars, and
    /// only a write that succeeded may pass one: the recorded order is what a
    /// read trusts to find the newest payload.
    func setNamingMetadata(
        jobID: UUID, slug: String?, usedDiarizerMode: DiarizerMode?, wroteSidecarsIn: URL?,
    )
    /// Apply a speaker DB update AND refresh the queue's cached known-names in
    /// one step (issue #155): the write+refresh pairing must stay atomic.
    /// `jobID` lets the queue tell the user, once per job, about a voice the
    /// DB could not take.
    func updateSpeakerDB(
        matcher: SpeakerMatcher, mapping: [String: String],
        embeddings: [String: [Float]], speakingTimes: [String: TimeInterval],
        jobID: UUID,
    )
    /// Run the LLM protocol generator over a transcript (a queue pipeline stage).
    /// Throws only `CancellationError`, once the job has been cancelled or
    /// removed; nothing is saved for it then.
    func generateProtocol(
        jobID: UUID, transcript: String, title: String, protocolsDir: URL, speakerNames: [String],
    ) async throws(CancellationError)
    /// Diarize app + mic tracks separately with the shared single-track fallback
    /// (app-only on mic failure, mic-only on app failure; a queue pipeline stage,
    /// reused by the late re-run).
    func runDualTrackDiarization(
        diarizeProcess: any DiarizationProvider,
        tracks: (app: URL, mic: URL, micDelay: TimeInterval, viability: DualTrackViability?),
        speakerCount: Int?, title: String, jobID: UUID,
    ) async throws -> DiarizationRun
    /// Render the speaker-labeled transcript from a diarization run + cached
    /// transcript segments (a queue pipeline stage, reused by the late rewrite).
    func renderLabeledTranscript( // swiftlint:disable:this function_parameter_count
        run: DiarizationRun, cachedSegments: [TimestampedSegment],
        isDualSource: Bool, autoNames: [String: String], note: String?, micMuted: [MicMuteInterval],
    ) -> String?
}

extension SpeakerNamingSessionDelegate {
    /// Convenience wrapper so call sites that never carry an error message can
    /// omit the `error:` argument.
    func updateJobState(id: UUID, to newState: JobState) {
        updateJobState(id: id, to: newState, error: nil)
    }

    /// Whether a job's work goes on: the task doing it was not cancelled and
    /// the job is still tracked. A cancelled job writes nothing further, and
    /// this is the one rule both the queue's stages and the session's writers
    /// check before a write. The task flag counts because only the job's own
    /// cancel or removal cancels the tasks that do its work. Also what tells
    /// a cancelled run apart from a failed one, since a step stopped by a
    /// cancellation may report an error of its own.
    func isStillQueued(_ jobID: UUID) -> Bool {
        !Task.isCancelled && job(withID: jobID) != nil
    }
}
