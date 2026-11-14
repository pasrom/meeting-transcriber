import Foundation

/// Retrying meeting notes that could not be generated, from the transcript the
/// job saved. A failed generation leaves the job `.done` with its transcript
/// and `protocolFailure` set; such a job stays listed (`isHeldAfterCompletion`)
/// until it is retried or dismissed.
extension PipelineQueue {
    /// Matched by /v1 clients and persisted jobs; keep the text stable.
    static let protocolGenerationFailedWarning = "Protocol generation failed — transcript saved"
    static let notesRetryTranscriptMissingWarning =
        "The saved transcript could not be read, so the meeting notes were not retried"
    static let notesRetryNotesExistWarning =
        "Meeting notes already exist next to the transcript, so they were not generated again"

    /// Whether the menu offers Retry Meeting Notes for this job. State only,
    /// like `canRetryJob`: the transcript can sit on a network volume, so
    /// `retryMeetingNotes` checks the file on every click instead.
    func canRetryMeetingNotes(id: UUID) -> Bool {
        jobs.first { $0.id == id }?.hasRetryableMeetingNotes ?? false
    }

    /// The jobs Retry All Meeting Notes would run, in queue order.
    var jobsWithRetryableMeetingNotes: [PipelineJob] {
        jobs.filter(\.hasRetryableMeetingNotes)
    }

    /// Generates the meeting notes again from the saved transcript, without
    /// transcribing or diarizing again: the job goes back to `.waiting`
    /// marked for the protocol-only resume a restore uses
    /// (`resumeProtocolOnly`), so it runs in turn with the rest of the queue.
    ///
    /// Never overwrites notes: when a `.md` of the transcript's name exists
    /// (written by hand, or by a run outside the app) the job stops offering
    /// the retry and says why. A transcript that cannot be read leaves the
    /// offer in place, so a volume that comes back is retryable again.
    @discardableResult
    func retryMeetingNotes(id: UUID) -> Bool {
        guard canRetryMeetingNotes(id: id),
              let index = jobs.firstIndex(where: { $0.id == id }),
              let transcriptPath = jobs[index].transcriptPath else { return false }
        if Self.existingNotes(for: jobs[index], transcriptPath: transcriptPath) {
            jobs[index].protocolFailure = nil
            addWarning(id: id, Self.notesRetryNotesExistWarning)
            saveSnapshot()
            scheduleCompletedJobRemoval(id: id)
            return false
        }
        // The resume falls back to a full run when it cannot read the
        // transcript, and a notes retry must never turn into one.
        guard let transcript = try? String(contentsOf: transcriptPath, encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            addWarning(id: id, Self.notesRetryTranscriptMissingWarning)
            saveSnapshot()
            return false
        }
        jobs[index].protocolFailure = nil
        jobs[index].warnings.removeAll { warning in
            warning == Self.protocolGenerationFailedWarning || warning == Self.notesRetryTranscriptMissingWarning
        }
        protocolResumeDispositions[id] = .resumeProtocolOnly
        eventLog.append(jobID: id, event: "meeting_notes_retry", from: .done, to: .waiting)
        updateJobState(id: id, to: .waiting)
        triggerProcessing()
        return true
    }

    /// Retries every job `jobsWithRetryableMeetingNotes` lists. They queue up
    /// and run one after another. Returns the IDs of the ones that started.
    @discardableResult
    func retryAllMeetingNotes() -> [UUID] {
        jobsWithRetryableMeetingNotes.map(\.id).filter { retryMeetingNotes(id: $0) }
    }

    /// The names a retry would write the notes under: the job's stem, and the
    /// transcript's own name for a job whose stem no longer matches it.
    private static func existingNotes(for job: PipelineJob, transcriptPath: URL) -> Bool {
        let folder = transcriptPath.deletingLastPathComponent()
        let stems = Set([job.namingSlug, transcriptPath.deletingPathExtension().lastPathComponent].compactMap(\.self))
        return stems.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0).md").path) }
    }
}
