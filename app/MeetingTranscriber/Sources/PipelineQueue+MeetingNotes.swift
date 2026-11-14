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

/// What `enqueueNotes(fromTranscripts:)` did with each file it was given.
struct NotesFromTranscriptOutcome: Equatable {
    /// One job per transcript, in the order given.
    var queued: [UUID] = []
    /// Transcripts with a `.md` of the same name next to them. Never overwritten.
    var notesExist: [URL] = []
    /// Not a `.txt`, missing, empty or unreadable.
    var unreadable: [URL] = []

    /// The notification for files that were not queued, nil when all were.
    var skippedNotice: (title: String, body: String)? {
        var parts: [String] = []
        if !notesExist.isEmpty { parts.append("Notes already exist for \(Self.names(notesExist)).") }
        if !unreadable.isEmpty { parts.append("Could not read \(Self.names(unreadable)).") }
        guard !parts.isEmpty else { return nil }
        return ("Some Transcripts Were Skipped", parts.joined(separator: " "))
    }

    private static func names(_ urls: [URL]) -> String {
        urls.map(\.lastPathComponent).joined(separator: ", ")
    }
}

/// Meeting notes for a transcript the user picks, typically one from before
/// the notes were generated or from before they failed and the job is gone.
extension PipelineQueue {
    static let notesOnlyTranscriptUnreadableError = "The transcript could not be read"
    static let notesOnlyNotesExistError = "Meeting notes already exist next to the transcript"

    /// Queues one notes-only job per transcript. They run one after another
    /// with the rest of the queue.
    ///
    /// The transcript stays where it is, under its own name: the job keeps the
    /// raw transcript whatever the setting, and never renames by the AI title,
    /// since both would act on a file the user picked rather than one the run
    /// wrote. The notes go next to it as `<name>.md`, and a transcript that
    /// already has one is left out. A name that starts with the app's
    /// `yyyyMMdd_HHmm` stamp gives the notes their meeting date.
    @discardableResult
    func enqueueNotes(fromTranscripts urls: [URL]) -> NotesFromTranscriptOutcome {
        var outcome = NotesFromTranscriptOutcome()
        for url in urls {
            guard url.pathExtension.lowercased() == "txt", Self.readTranscript(at: url) != nil else {
                outcome.unreadable.append(url)
                continue
            }
            guard !FileManager.default.fileExists(atPath: Self.notesURL(forTranscript: url).path) else {
                outcome.notesExist.append(url)
                continue
            }
            let stem = url.deletingPathExtension().lastPathComponent
            var job = PipelineJob(
                meetingTitle: stem, appName: "Transcript", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
                meetingStartTime: Self.meetingStart(fromStem: stem),
                saveRawTranscriptSeparately: true, useAITitleForFilenames: false,
            )
            job.transcriptPath = url
            job.namingSlug = stem
            job.generatesNotesOnly = true
            enqueue(job)
            outcome.queued.append(job.id)
        }
        return outcome
    }

    /// The notes step of a notes-only job. Checked again here, since the job
    /// may have waited behind others: a transcript gone or notes written in
    /// the meantime end the job in an error rather than in a full run or an
    /// overwrite.
    func generateNotesOnly(_ job: PipelineJob) async {
        guard let transcriptPath = job.transcriptPath, let transcript = Self.readTranscript(at: transcriptPath) else {
            updateJobState(id: job.id, to: .error, error: Self.notesOnlyTranscriptUnreadableError)
            return
        }
        guard !FileManager.default.fileExists(atPath: Self.notesURL(forTranscript: transcriptPath).path) else {
            updateJobState(id: job.id, to: .error, error: Self.notesOnlyNotesExistError)
            return
        }
        do {
            try await generateProtocol(
                jobID: job.id, transcript: transcript, title: job.meetingTitle,
                protocolsDir: transcriptPath.deletingLastPathComponent(),
            )
            updateJobState(id: job.id, to: .done)
        } catch {
            // Cancelled with its job: nothing is left to finish.
        }
    }

    private static func readTranscript(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func notesURL(forTranscript url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("md")
    }

    private static let stemStampFormatter = DateFormatter.filenameStamp("yyyyMMdd_HHmm")

    /// The meeting start a name like `20261030_0900_standup` records, nil
    /// for any other name.
    static func meetingStart(fromStem stem: String) -> Date? {
        guard stem.count >= 13 else { return nil }
        return stemStampFormatter.date(from: String(stem.prefix(13)))
    }
}
