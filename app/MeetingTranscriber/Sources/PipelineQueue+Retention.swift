import Foundation

/// The queue's side of the recording retention setting: it records what stage 3
/// moved, says when a job finished with its outputs written, and runs the
/// cleaner with the paths its unfinished jobs hold. Every call is a no-op on a
/// queue built without a `RecordingRetention`.
extension PipelineQueue {
    /// Record the tracks stage 3 moved, as `persistAudioToOutput` reports
    /// them: never an import, a file already in the output folder or a failed
    /// move. Called right after the move, not at `.done`: a run restored after
    /// a quit finds its audio already in the output folder, reads it as
    /// "already at destination" and moves nothing, so an entry left for the
    /// end would never be written for it.
    func registerRelocatedAudio(jobID: UUID, moved: [URL], root: URL) {
        guard let recordingRetention,
              let job = jobs.first(where: { $0.id == jobID }) else { return }
        recordingRetention.registry.register(
            jobID: jobID, paths: moved, root: root, recordedAt: job.artifactStartTime,
        )
    }

    /// Mark the job's recording due for retention now that `output`, the
    /// output the run meant to produce, is written: the saved protocol, or
    /// with no protocol provider the transcript. Called where that output is
    /// produced (the exits of `generateProtocol`, a restore that finds the
    /// protocol already written, and accepting the auto-names with no
    /// provider), never at `.done`, which a failed protocol run, a confirm
    /// that could not write the names and a restore that lost the naming data
    /// all reach too. Before the job is done the cleaner still keeps the
    /// recording, since the job holds its tracks.
    func markOutputWritten(jobID: UUID, output: URL?) {
        // Named is not written: the file has to be there, with content.
        guard let recordingRetention, let output, RecordingRetentionPolicy.isWrittenFile(output) else { return }
        recordingRetention.registry.markEligible(jobID: jobID, output: output, at: Date())
    }

    /// Run a retention pass with this queue's output folder and its unfinished
    /// jobs. Returns once the pass (or the one it joined) is done.
    func sweepRetainedRecordings() async {
        await recordingRetention?.sweep(retentionSweepContext)
    }

    /// What a pass run on this queue's behalf needs: its output folder, its
    /// scope access and the tracks its unfinished jobs hold.
    private var retentionSweepContext: RecordingRetention.SweepContext {
        .init(
            excludedPaths: { [weak self] in self?.retentionExcludedPaths ?? [] },
            scopeRoot: scopedOutputDir,
            securityScope: securityScope,
        )
    }

    /// Every track of every job in this queue that is not done. All three
    /// tracks, because a run reads `_app.wav` and `_mic.wav` too.
    ///
    /// This queue's jobs are the whole answer: the controller replaces a queue
    /// only once all its jobs are finished, so no other queue is running one.
    /// The in-flight claims are added as a backstop only; they name the mix
    /// path a run was claimed with, usually the staging path, so they rarely
    /// match a relocated file.
    var retentionExcludedPaths: Set<String> {
        inFlightRuns.claimedAudioPaths.union(Self.heldTrackKeys(of: jobs))
    }

    /// Every track of every job in `jobs` that is not done, in the form the
    /// policy compares paths in. Shared by the queue and by the pass that runs
    /// before a queue is built, which reads the jobs from the snapshot.
    static func heldTrackKeys(of jobs: [PipelineJob]) -> Set<String> {
        Set(jobs.filter { $0.state != .done }
            .flatMap(\.audioPaths)
            .map(RecordingRetentionPolicy.pathKey))
    }
}
