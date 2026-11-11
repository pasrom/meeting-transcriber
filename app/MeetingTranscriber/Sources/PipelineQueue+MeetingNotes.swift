import Foundation

/// Retrying meeting notes that could not be generated, from the transcript the
/// job saved. A failed generation leaves the job `.done` with its transcript
/// and `notesFailure` set; such a job stays listed (`isHeldAfterCompletion`)
/// until it is retried or dismissed.
extension PipelineQueue {
    /// Matched by /v1 clients and persisted jobs; keep the text stable.
    static let protocolGenerationFailedWarning = "Protocol generation failed — transcript saved"
    static let notesRetryTranscriptMissingWarning =
        "The saved transcript could not be read, so no meeting notes were made"
    static let notesRetryNotesExistWarning =
        "Meeting notes already exist next to the transcript, so they were not generated again"
    static let notesWrittenMeanwhileWarning =
        "Meeting notes were generated, but notes had appeared next to the transcript in the meantime, so they were not written"
    static let notesRetryNoProviderWarning =
        "Choose a meeting notes provider in Settings → Output to make the meeting notes"
    /// Matched by /v1 clients and persisted jobs; keep the text stable.
    static let rawTranscriptRetainedWithoutNotesWarning = "Raw transcript retained because no protocol was saved"

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
    /// transcribing or diarizing again: the job goes back to `.waiting` with
    /// `generatesNotesOnly`, which `runPipeline` sends to `generateNotesOnly`,
    /// so it runs in turn with the rest of the queue, also after a relaunch.
    ///
    /// The failure stays on the job until the notes are saved (`updateJobState`
    /// clears it then), so a retry that fails again is still on offer. Refused
    /// while the provider is None, where it would end without notes. Never
    /// overwrites notes: a `.md` of the job's stem or the transcript's name
    /// ends the offer with a warning, here and again after the model call.
    @discardableResult
    func retryMeetingNotes(id: UUID) -> Bool {
        guard canRetryMeetingNotes(id: id),
              let index = jobs.firstIndex(where: { $0.id == id }),
              let transcriptPath = jobs[index].transcriptPath else { return false }
        guard protocolGeneratorFactory?() != nil else {
            addWarning(id: id, Self.notesRetryNoProviderWarning)
            saveSnapshot()
            return false
        }
        if Self.existingNotes(for: jobs[index], transcriptPath: transcriptPath) {
            stopOfferingNotesRetry(id: id, warning: Self.notesRetryNotesExistWarning)
            scheduleCompletedJobRemoval(id: id)
            return false
        }
        // A file check only; the transcript is read when the job runs.
        guard FileManager.default.fileExists(atPath: transcriptPath.path) else {
            addWarning(id: id, Self.notesRetryTranscriptMissingWarning)
            saveSnapshot()
            return false
        }
        jobs[index].generatesNotesOnly = true
        eventLog.append(jobID: id, event: "meeting_notes_retry", from: .done, to: .waiting)
        updateJobState(id: id, to: .waiting)
        triggerProcessing()
        return true
    }

    /// The notes step of a notes-only job. A transcript that cannot be read
    /// ends it `.done` again with a warning and the retry still on offer, so a
    /// volume that comes back is retryable; notes that appeared while it waited
    /// end the offer. Neither becomes a full run or an overwrite.
    func generateNotesOnly(_ job: PipelineJob) async {
        guard let transcriptPath = job.transcriptPath, let transcript = Self.readTranscript(at: transcriptPath) else {
            // The failure this time is the transcript, so that is what the
            // notification names.
            recordNotesFailure(id: job.id, .transcriptUnreadable)
            addWarning(id: job.id, Self.notesRetryTranscriptMissingWarning)
            updateJobState(id: job.id, to: .done)
            return
        }
        if Self.existingNotes(for: job, transcriptPath: transcriptPath) {
            stopOfferingNotesRetry(id: job.id, warning: Self.notesRetryNotesExistWarning)
            updateJobState(id: job.id, to: .done)
            return
        }
        do {
            try await generateProtocol(
                jobID: job.id, transcript: transcript, title: job.meetingTitle,
                protocolsDir: transcriptPath.deletingLastPathComponent(),
                speakerNames: job.notesSpeakerNames ?? job.notionExportSpeakerNames ?? [],
                // A retry owes notes: without a provider it stays on offer.
                transcriptIsTheOutputWithoutAProvider: false,
            )
            // `generateProtocol` returns without a word when the provider was
            // switched to None while the job waited.
            if protocolGeneratorFactory?() == nil, self.job(withID: job.id)?.hasSavedProtocol == false {
                recordNotesFailure(id: job.id, .noProvider)
                addWarning(id: job.id, Self.notesRetryNoProviderWarning)
            }
            updateJobState(id: job.id, to: .done)
        } catch {
            // Cancelled with its job: nothing is left to finish.
        }
    }

    /// Keeps the names the failed notes were to carry for the retry.
    func recordNotesSpeakerNames(id: UUID, _ names: [String]) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].notesSpeakerNames = names
    }

    /// A notes-only job never replaces notes that appeared while the model
    /// ran: true, with the offer ended, when they did.
    func notesAppearedDuringTheCall(of job: PipelineJob, basename: String, protocolsDir: URL) -> Bool {
        guard job.generatesNotesOnly == true,
              FileManager.default.fileExists(atPath: protocolsDir.appendingPathComponent("\(basename).md").path)
        else { return false }
        stopOfferingNotesRetry(id: job.id, warning: Self.notesWrittenMeanwhileWarning)
        return true
    }

    /// Notes exist next to the transcript: the job stops offering a retry
    /// (and leaves the list like any finished job) and says why. The
    /// notes-only marker stays, so the done notification can tell that this
    /// run ended without notes.
    func stopOfferingNotesRetry(id: UUID, warning: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].notesFailure = nil
        addWarning(id: id, warning)
        saveSnapshot()
    }

    /// The notes are saved: the failure, the notes-only marker and the warnings
    /// that described the job without notes go.
    func clearNotesFailure(at index: Int) {
        jobs[index].notesFailure = nil
        jobs[index].generatesNotesOnly = nil
        jobs[index].notesSpeakerNames = nil
        let stale = [
            Self.protocolGenerationFailedWarning, Self.notesRetryTranscriptMissingWarning,
            Self.notesRetryNoProviderWarning, Self.rawTranscriptRetainedWithoutNotesWarning,
        ]
        jobs[index].warnings.removeAll { stale.contains($0) }
    }

    /// Retries every job `jobsWithRetryableMeetingNotes` lists. They queue up
    /// and run one after another. Returns the IDs of the ones that started.
    @discardableResult
    func retryAllMeetingNotes() -> [UUID] {
        jobsWithRetryableMeetingNotes.map(\.id).filter { retryMeetingNotes(id: $0) }
    }

    /// The names a retry would write the notes under: the job's stem, and the
    /// transcript's own name for a job whose stem no longer matches it.
    static func existingNotes(for job: PipelineJob, transcriptPath: URL) -> Bool {
        let folder = transcriptPath.deletingLastPathComponent()
        let stems = Set([job.namingSlug, transcriptPath.deletingPathExtension().lastPathComponent].compactMap(\.self))
        return stems.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0).md").path) }
    }

    /// The transcript, nil when it is missing, unreadable or blank.
    static func readTranscript(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
