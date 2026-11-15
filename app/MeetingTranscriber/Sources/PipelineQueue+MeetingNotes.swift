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
        guard let transcriptPath = job.transcriptPath, let transcript = await Self.readTranscriptOffMain(transcriptPath)
        else {
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
            let outcome = try await generateProtocol(
                jobID: job.id, transcript: transcript, title: job.meetingTitle,
                protocolsDir: transcriptPath.deletingLastPathComponent(),
                speakerNames: job.notesSpeakerNames ?? job.notionExportSpeakerNames ?? [],
                // A retry owes notes: without a provider it stays on offer.
                transcriptIsTheOutputWithoutAProvider: false,
            )
            // `generateProtocol` records nothing on the job when the provider
            // was switched to None while the job waited.
            if outcome == .noProvider, self.job(withID: job.id)?.hasSavedProtocol == false {
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

    /// `readTranscript` off the main actor, for a file the caller named: it
    /// can be on a slow volume, and up to `maxTranscriptBytes`.
    static func readTranscriptOffMain(_ url: URL) async -> String? {
        await Task.detached { readTranscript(at: url) }.value
    }

    /// The transcript, nil when it is missing, unreadable, blank or larger
    /// than `maxTranscriptBytes`.
    nonisolated static func readTranscript(at url: URL) -> String? {
        guard let size = fileSize(url), size <= maxTranscriptBytes else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// How `PipelineQueue.generateProtocol` ended, as far as a caller has to tell
/// the ends apart.
enum ProtocolGenerationOutcome {
    /// No provider is chosen: no model call was made, and nothing about the
    /// notes was recorded on the job.
    case noProvider
    /// Every other end. What came of it is on the job: the notes, a failure
    /// or a warning.
    case attempted
}

/// What `enqueueNotes(fromTranscripts:)` did with each file it was given.
struct NotesFromTranscriptOutcome: Equatable {
    /// One job per transcript, in the order given.
    var queued: [UUID] = []
    /// Transcripts with a `.md` of the same name next to them. Never overwritten.
    var notesExist: [URL] = []
    /// Not a `.txt`, missing, empty or larger than `maxTranscriptBytes`.
    var unreadable: [URL] = []
    /// Given twice, or already waiting in a notes-only job.
    var alreadyQueued: [URL] = []

    /// The notification for files that were not queued, nil when all were.
    var skippedNotice: (title: String, body: String)? {
        var parts: [String] = []
        if !notesExist.isEmpty { parts.append("Notes already exist for \(Self.names(notesExist)).") }
        if !unreadable.isEmpty { parts.append("Could not read \(Self.names(unreadable)).") }
        if !alreadyQueued.isEmpty { parts.append("Already queued: \(Self.names(alreadyQueued)).") }
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
    /// Queues one notes-only job per transcript. They run one after another
    /// with the rest of the queue.
    ///
    /// The transcript stays where it is, under its own name: the job keeps the
    /// raw transcript whatever the setting, and never renames by the AI title,
    /// since both would act on a file the user picked rather than one the run
    /// wrote. The notes go next to it as `<name>.md`, and a transcript that
    /// already has one is left out. A name that starts with the app's
    /// `yyyyMMdd_HHmm` stamp gives the notes their meeting date.
    ///
    /// Nothing is read here, on the main actor: a file is checked by its name
    /// and size, and read off the main actor when its job runs
    /// (`generateNotesOnly`). The same transcript is queued once, whether it
    /// is given twice or is already waiting in a notes-only job.
    @discardableResult
    func enqueueNotes(fromTranscripts urls: [URL]) -> NotesFromTranscriptOutcome {
        var outcome = NotesFromTranscriptOutcome()
        var queuedPaths = Set(jobs.filter { $0.generatesNotesOnly == true && !$0.state.isTerminal }
            .compactMap { $0.transcriptPath?.standardizedFileURL.path })
        for url in urls {
            guard url.pathExtension.lowercased() == "txt", Self.isTranscriptSized(url) else {
                outcome.unreadable.append(url)
                continue
            }
            guard !FileManager.default.fileExists(atPath: Self.notesURL(forTranscript: url).path) else {
                outcome.notesExist.append(url)
                continue
            }
            guard queuedPaths.insert(url.standardizedFileURL.path).inserted else {
                outcome.alreadyQueued.append(url)
                continue
            }
            let stem = url.deletingPathExtension().lastPathComponent
            var job = PipelineJob(
                meetingTitle: stem, appName: "Transcript", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
                meetingStartTime: Self.meetingStart(fromStem: stem),
                saveRawTranscriptSeparately: true, useAITitleForFilenames: false,
            )
            job.transcriptPath = url
            job.notesBasename = stem
            job.generatesNotesOnly = true
            enqueue(job)
            outcome.queued.append(job.id)
        }
        return outcome
    }

    /// Above it a file is not taken for a transcript. A guard, not a measured
    /// bound: the app's own transcripts are text of one meeting.
    nonisolated static let maxTranscriptBytes = 16 * 1024 * 1024

    private static func isTranscriptSized(_ url: URL) -> Bool {
        guard let size = fileSize(url) else { return false }
        return size > 0 && size <= maxTranscriptBytes
    }

    /// The size of what a read would read: `attributesOfItem` describes a
    /// symbolic link itself, while `String(contentsOf:)` follows it.
    nonisolated static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? Int
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
