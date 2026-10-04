import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// Snapshot restore and orphaned-recording recovery for `PipelineQueue`, split
/// out of `PipelineQueue.swift` so the primary class body drops under the
/// `type_body_length` lint cap. An extension of a globally `@MainActor`-isolated
/// type inherits that isolation, so the moved methods need no explicit
/// annotation. Pure move; no behavior change.
extension PipelineQueue {
    // MARK: - Adopting the jobs of a replaced queue

    /// Take over the state of the queue this one replaces, instead of reading
    /// the snapshot file.
    ///
    /// The counterpart to `loadSnapshot()`, and it has to make the same
    /// decisions, because the only difference is where the jobs come from. A
    /// folder change is triggered by the very job transition whose snapshot
    /// write is still in flight, so the file on disk can still show a finished
    /// job as running; restoring it from there would queue that job a second
    /// time (issue #744). The queue being replaced holds the current state in
    /// memory, and the caller has already checked that it holds no unfinished
    /// work.
    ///
    /// Finished jobs are dropped with their sidecars, exactly as the restore
    /// drops them. Keeping them looked harmless and is not: the reaper that
    /// removes a `.done` job after `completedJobLifetime` is a task owned by the
    /// queue the job came from, so an adopted job would carry no reaper, sit in
    /// the list and the snapshot indefinitely, keep its 16 kHz sidecars in the
    /// folder the user navigated away from, and offer the menu an "open" that
    /// reaches into a folder whose security scope died with the old queue.
    /// Failed jobs are kept, because the restore keeps them and a retry is
    /// what cleans up after them.
    func adoptJobs(of replaced: PipelineQueue) {
        // Before anything is written: the replaced queue may still owe a write,
        // and both queues share one staging file. See `discardPendingSnapshot`.
        replaced.discardPendingSnapshot()
        var adopted = replaced.jobs
        discardFinishedJobs(from: &adopted)
        discardJobsWithMissingAudio(&adopted, interruptedIn: [:])
        // Count, not equality: both calls above only ever remove, so a
        // differing count is exactly "something was dropped". `PipelineJob` is
        // not `Equatable`, and making it so for one bookkeeping line would put
        // a conformance on a type with two dozen fields.
        let changed = adopted.count != replaced.jobs.count
        jobs = adopted
        // Only when this queue's list differs from what the replaced one held.
        // Every rebuild comes through here once the controller has built a queue
        // itself, including each watch start, and writing an unchanged (usually
        // empty) list would spend an atomic replace on nothing. The replace is
        // the syscall this queue keeps a serializing actor for.
        if changed { saveSnapshot() }
    }

    /// Drop finished jobs and let their sidecars go with them.
    ///
    /// Shared by the restore and the adoption so the two cannot drift: both
    /// start a queue's job list, and which jobs a fresh list may contain is one
    /// decision, not two. It used to be written out at both call sites, held
    /// together only by a comment saying they had to agree.
    private func discardFinishedJobs(from list: inout [PipelineJob]) {
        let finished = list.filter { $0.state == .done }
        guard !finished.isEmpty else { return }
        list.removeAll { $0.state == .done }
        removeNamingDataOfDiscardedJobs(finished)
    }

    // MARK: - Snapshot Recovery

    /// Load pipeline queue from the JSON snapshot written by `saveSnapshot()`.
    /// Resets in-progress jobs to `.waiting`, discards `.done` jobs, and drops
    /// jobs whose `mixPath` no longer exists on disk.
    func loadSnapshot() {
        var loaded: [PipelineJob]
        do {
            guard let decoded = try PipelineSnapshot.load(from: logDir) else {
                logger.info("No pipeline snapshot to restore")
                return
            }
            loaded = decoded
        } catch {
            logger.error("Failed to load pipeline snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }

        // The reset below overwrites the state a job was interrupted in, which
        // is the one field a discard record is worth reading for.
        let interruptedStates = Dictionary(loaded.map { ($0.id, $0.state) }) { _, last in last }

        protocolResumeDispositions = resumeDispositions(for: loaded)

        // Reset active states back to waiting
        for i in loaded.indices {
            switch loaded[i].state {
            case .transcribing, .diarizing, .generatingProtocol:
                loaded[i].state = .waiting

            default:
                break
            }
        }

        discardFinishedJobs(from: &loaded)

        discardJobsWithMissingAudio(&loaded, interruptedIn: interruptedStates)

        // Drop what another queue is still running. This is where issue #558
        // brought the job back: a replacement queue reads the same snapshot,
        // finds the job recorded as active, resets it to waiting above and
        // starts it a second time. Speaker naming is exempt because a job
        // parked there is waiting on the user, not executing.
        let beforeInFlightDrop = loaded.count
        loaded.removeAll { job in
            job.state != .speakerNamingPending && inFlightRuns.isInFlight(job)
        }
        let droppedInFlight = loaded.count < beforeInFlightDrop

        // Before the exits below, so a dropped job cannot leave its disposition
        // behind for the session.
        let survivingIDs = Set(loaded.map(\.id))
        protocolResumeDispositions = protocolResumeDispositions.filter { survivingIDs.contains($0.key) }

        guard !loaded.isEmpty else {
            logger.info("Snapshot loaded but no recoverable jobs")
            // Rewrite the file, or a job discarded for good is read, discarded
            // and logged again on every launch from here on, and the record of
            // the loss cannot be told apart from the re-reads of it. Skipped
            // when the in-flight rule dropped something: that job belongs to a
            // queue still running it, whose own transitions own the file.
            if !droppedInFlight { saveSnapshot() }
            return
        }

        jobs = loaded

        // Rebuild the session's naming cache from disk for
        // .speakerNamingPending jobs.
        let missingNamingDataJobIDs = jobs.compactMap { job -> UUID? in
            guard job.state == .speakerNamingPending else { return nil }
            if let slug = job.namingSlug,
               naming.restore(jobID: job.id, slug: slug, in: sidecarDir(of: job)) {
                return nil
            }
            logger.warning("Naming data not found for job \(job.id), marking as done")
            return job.id
        }
        // Naming data lost — use the normal transition so terminal handling,
        // artifact retention, callbacks, and the durable job record stay in
        // sync with every other completion path.
        for jobID in missingNamingDataJobIDs {
            updateJobState(id: jobID, to: .done)
        }

        saveSnapshot()
        cleanupStalePending()
        logger.info("Restored \(loaded.count) jobs from snapshot")
        triggerProcessing()
        // Auto-popup the naming dialog if any restored job is still
        // waiting for confirmation. Same notification as the in-pipeline
        // pop, so MeetingTranscriberApp brings the window forward.
        if !pendingSpeakerNamingJobs.isEmpty {
            NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)
        }
    }

    /// What to do with each job that was interrupted mid-run, decided before
    /// the reset loop overwrites the state it is decided from.
    ///
    /// The filesystem is only touched for a job that could actually use the
    /// answer. `loadSnapshot` runs on the main actor at launch, and the output
    /// folder may be a network mount, so statting every restored job's
    /// transcript here would be blocking work the state guard then discards.
    private func resumeDispositions(for loaded: [PipelineJob]) -> [UUID: ProtocolResumeDisposition] {
        var dispositions: [UUID: ProtocolResumeDisposition] = [:]
        for job in loaded where job.state == .generatingProtocol {
            let store = SpeakerNamingStore(outputDir: sidecarDir(of: job))
            let disposition = ProtocolResumePolicy.decide(
                interruptedIn: job.state,
                namingDataOnDisk: store.hasNamingData(slug: job.namingSlug),
                transcriptExists: Self.fileExists(job.transcriptPath),
                hasNamingSlug: job.namingSlug != nil,
                protocolExists: Self.fileExists(job.protocolPath),
            )
            if disposition != .fullRun { dispositions[job.id] = disposition }
        }
        return dispositions
    }

    private static func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Finish a job the app was killed in the middle of generating a protocol
    /// for, without re-running the stages whose results are already on disk.
    ///
    /// Re-running them is not merely slower. A late confirm transits
    /// `.generatingProtocol` too, and a full run there would re-diarize, throw
    /// away the names the user had just confirmed and park the job back in the
    /// dialog they had just closed.
    ///
    /// `protocolsDir` comes from the transcript's own location rather than the
    /// current `outputDir`, because the setting may have been repointed since
    /// the run and the `.md` belongs beside the `.txt` it was made from.
    ///
    /// Returns false when the transcript turned out to be unreadable, so the
    /// caller falls back to the full run instead of finishing a job with
    /// nothing to show.
    func resumeProtocolOnly(_ job: PipelineJob) async -> Bool {
        // Peeked, not consumed: a transcript that turns out unreadable this
        // launch (a volume not mounted yet) must not permanently downgrade the
        // job to a full run.
        guard let disposition = protocolResumeDispositions[job.id] else { return false }
        if disposition == .finish {
            // Killed between writing the protocol and the terminal transition.
            // Everything is on disk; a second LLM call would only overwrite an
            // identical file.
            protocolResumeDispositions.removeValue(forKey: job.id)
            eventLog.append(jobID: job.id, event: "finished_after_restore", from: .waiting, to: .done)
            updateJobState(id: job.id, to: .done)
            return true
        }
        guard let transcriptPath = job.transcriptPath,
              let transcript = try? String(contentsOf: transcriptPath, encoding: .utf8),
              // The same bar the main pipeline sets: a crash mid-write leaves a
              // truncated or empty file, and spending an LLM call on it would
              // publish whatever came back as the meeting protocol.
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            addWarning(id: job.id, "Could not read the saved transcript; the meeting was processed again")
            return false
        }
        protocolResumeDispositions.removeValue(forKey: job.id)
        eventLog.append(
            jobID: job.id, event: "resumed_protocol_only",
            from: .waiting, to: .generatingProtocol,
        )
        await generateProtocol(
            jobID: job.id, transcript: transcript, title: job.meetingTitle,
            protocolsDir: transcriptPath.deletingLastPathComponent(),
        )
        stopElapsedTimer()
        updateJobState(id: job.id, to: .done)
        return true
    }

    /// Discard jobs whose audio file no longer exists, EXCEPT
    /// `.speakerNamingPending` — those have their own slug-based `_16k.wav`
    /// sidecar and don't need the original mix.wav. Paired imports with nil
    /// `mixPath`: keep them, `appPath` is the ground-truth source and it's
    /// checked at processNext time.
    ///
    /// Losing a job is worth a line. This used to drop one without a trace
    /// anywhere, which is how the quit-during-protocol-generation case stayed
    /// invisible: the job simply was not there any more, and the event log
    /// ended mid-run. A job that reaches this rule now leaves a record naming
    /// it, whether its audio was deleted, its relocation failed, or its
    /// snapshot predates the job carrying its relocated paths.
    private func discardJobsWithMissingAudio(
        _ loaded: inout [PipelineJob], interruptedIn: [UUID: JobState],
    ) {
        let missing = loaded.filter { job in
            guard let mixPath = job.mixPath else { return false }
            // Exempt, like `.speakerNamingPending`: a job the resume can finish
            // reads its transcript and nothing else, so discarding it for a
            // missing mix throws away the one thing that could still complete
            // the meeting.
            guard protocolResumeDispositions[job.id] == nil else { return false }
            return job.state != .speakerNamingPending
                && !FileManager.default.fileExists(atPath: mixPath.path)
        }
        guard !missing.isEmpty else { return }
        let missingIDs = Set(missing.map(\.id))
        loaded.removeAll { missingIDs.contains($0.id) }
        for job in missing {
            logger.warning("Discarded restored job \(job.shortID, privacy: .public): audio no longer at the recorded path")
            eventLog.append(
                jobID: job.id, event: "discarded_missing_audio",
                from: interruptedIn[job.id], to: job.state,
            )
        }
    }

    /// Drop the naming sidecars of the `.done` jobs the restore threw away.
    ///
    /// Dropping a job has to drop what belongs to it, the same rule `removeJob`
    /// follows unconditionally. This restore is the last owner of those files:
    /// the slug that names them lives on the job, nothing sweeps the output
    /// folder for orphans, and the reaping task that would normally remove them
    /// never runs for a job already gone by the time the app comes back. Left
    /// alone they stay for good, and for a dual-source hour that is hundreds of
    /// MB per job.
    ///
    /// **Only the `.done` rule feeds this.** The missing-audio rule now fires on
    /// three populations only: snapshots written before a job carried its
    /// relocated paths, files the user really did delete, and relocations that
    /// failed. The first of those can still be a late re-diarization or late
    /// re-confirm running on a queue that `rebuild()` swapped out, reading the
    /// very sidecars this would delete, and the registry cannot separate them
    /// because only `processNext` ever claims a run. So that rule keeps its
    /// hands off, at the price of leaving those legacy jobs' sidecars behind.
    ///
    /// The in-flight check below is not merely belt and braces: the transition
    /// to `.done` happens inside the claimed run, before `processNext` releases
    /// the claim, so an in-session `rebuild()` can restore a `.done` job that is
    /// still being worked on.
    ///
    /// The directory comes from the job, not from the current setting: the
    /// queue's `outputDir` is wherever the user points today, and repointing it
    /// would otherwise have this clean the new folder while the files sit in
    /// the old one, with the job that names them discarded in the same breath.
    ///
    /// Removals are synchronous on the main actor, unlike the snapshot write
    /// further down. The realistic set is one job, the measured worst case a
    /// few hundred unlinks, and the precedent for moving filesystem work off
    /// this actor is a rename deadlock rather than unlink.
    private func removeNamingDataOfDiscardedJobs(_ discarded: [PipelineJob]) {
        for job in discarded where !inFlightRuns.isInFlight(job) {
            naming.removeNamingData(
                jobID: job.id, slug: job.namingSlug, in: sidecarDir(of: job),
            )
        }
    }

    // MARK: - Retrying a Failed Job

    /// Run a failed job again from its audio. Returns false, and changes
    /// nothing, unless `canRetryJob` holds.
    ///
    /// A failed job stays listed, and in the snapshot, until it is dismissed,
    /// but nothing used to run it again: the only way back was finding the
    /// staged audio and importing it by hand. That matters most when the
    /// failure was the app's, fixed in a later version, since the restored job
    /// then fails for a reason that no longer exists.
    ///
    /// By hand on purpose, not automatic. Most failures are deterministic (a
    /// silent capture, audio the engine refuses), and re-running those on every
    /// launch would cost a full transcription and an error notification each
    /// time for nothing. The user can tell a transient failure from a
    /// permanent one; this code cannot.
    ///
    /// The job keeps its ID, so its snapshot entry and event-log history
    /// continue rather than forking. The processed ledger is not consulted: a
    /// retry is an explicit request, like a re-import.
    ///
    /// Refused for any job not in `.error`, and while another job here, or a
    /// run on another queue, still holds the same audio: two jobs for one
    /// recording would transcribe it twice and write two sets of outputs.
    ///
    /// Everything the failed run left keyed on this job goes first, since the
    /// retry reuses the ID and would otherwise inherit it:
    /// - the speaker-naming state (in-memory naming data, recognition stashes,
    ///   the sidecars on disk). Diarization parks it before stage 3 writes the
    ///   transcript, which can throw, and a retry that produced none of its own
    ///   would skip the protocol and park in the dialog with the old mapping;
    /// - the audio length the stage-timing stats charge to the job;
    /// - a protocol-only resume the restore marked and a failed full run left
    ///   behind, which would publish the failed run's undiarized draft;
    /// - the durable terminal record. The API answers from the live job while
    ///   there is one, and a retried job that is then cancelled leaves without
    ///   a new record, so the old error would be served for it again.
    @discardableResult
    func retryJob(id: UUID) -> Bool {
        guard canRetryJob(id: id), let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        naming.removeNamingData(
            jobID: id, slug: jobs[index].namingSlug, in: jobs[index].sidecarOutputDir,
        )
        jobAudioSeconds.removeValue(forKey: id)
        protocolResumeDispositions.removeValue(forKey: id)
        terminalJobStore?.remove(jobID: id)
        jobs[index].prepareForRetry()
        updateJobState(id: id, to: .waiting)
        triggerProcessing()
        return true
    }

    /// Whether `retryJob` would accept this job now. The menu shows Retry only
    /// where this holds, so a click is never a silent no-op.
    ///
    /// Decided live, never from the error text. A job refused because another
    /// run held its audio is a duplicate only while that run holds it: once the
    /// owner failed, was cancelled or was dismissed, nothing processes the
    /// recording any more and this job is the way back to it. An owner that
    /// finished keeps blocking for as long as it is listed, since retrying then
    /// would write the same meeting a second time.
    ///
    /// The job's own audio must still be there. That also covers the owner
    /// that moved it: stage 3 relocates a staged recording into the output
    /// folder, after which the two jobs name different paths and the hold
    /// check below cannot match them, but the duplicate's path is empty.
    func canRetryJob(id: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .error else { return false }
        return Self.sourceAudioExists(for: job) && !audioIsHeldElsewhere(for: job)
    }

    /// The file a run reads first: the mix, or for a paired import without
    /// one, the app track.
    private static func sourceAudioExists(for job: PipelineJob) -> Bool {
        guard let source = job.mixPath ?? job.appPath else { return false }
        return FileManager.default.fileExists(atPath: source.path)
    }

    /// Whether a run is claimed for this job or its mix file on any queue, or
    /// another job in this one that has not failed holds the same mix file.
    /// Paired imports without a mix file are compared by the claim alone.
    private func audioIsHeldElsewhere(for job: PipelineJob) -> Bool {
        if inFlightRuns.isInFlight(job) { return true }
        guard let key = job.mixPath?.standardizedFileURL.path else { return false }
        return jobs.contains { other in
            other.id != job.id && other.state != .error
                && other.mixPath?.standardizedFileURL.path == key
        }
    }

    // MARK: - Orphaned Recording Recovery

    /// Scan `recordingsDir` for `*_mix.wav` files not tracked by any loaded job.
    /// Creates recovery jobs for untracked recordings younger than `maxAge`.
    /// Skips files the pipeline is already finished with, successfully or not
    /// (tracked in processed_recordings.json).
    ///
    /// The directory scan + per-file `attributesOfItem` calls run on a
    /// detached task — startup callers don't block the UI on a potentially
    /// slow filesystem (e.g. iCloud-backed recordings dir). Mutations to
    /// `jobs` and the snapshot still happen on the main actor.
    func recoverOrphanedRecordings(
        recordingsDir: URL = AppPaths.recordingsDir,
        maxAge: TimeInterval = 86400,
    ) async {
        // One-time migration: seed processed list with existing recordings
        // Only for the default recordings directory (not test overrides)
        if recordingsDir == AppPaths.recordingsDir {
            await processedLedger.migrate(recordingsDir: recordingsDir)
        }

        // Both reads happen here, on the main actor, before the detached hop:
        // the registry is main-actor isolated, and reading it from inside the
        // detached task would be a different question anyway, asked later.
        let trackedPaths = Set(jobs.compactMap { $0.mixPath?.standardizedFileURL.path })
        let runningPaths = inFlightRuns.claimedAudioPaths
        let ledger = processedLedger

        // Off-main: directory scan + processed-list read + per-file
        // attributesOfItem probes + filtering all happen here.
        let candidates: [PairedRecordingResolver.Group] = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: recordingsDir,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            ) else { return [] }
            let processedPaths = ledger.load()
            let now = Date()
            return PairedRecordingResolver.resolve(urls: entries).paired.filter { group in
                // Groups without a real mix file (app+mic-only paired imports)
                // aren't recoverable from the dir scan alone.
                guard let mixURL = group.mix else { return false }
                let stdPath = mixURL.standardizedFileURL.path
                guard !trackedPaths.contains(stdPath) else { return false }
                guard !runningPaths.contains(stdPath) else { return false }
                guard !processedPaths.contains(stdPath) else { return false }
                let attrs = try? fm.attributesOfItem(atPath: mixURL.path)
                if let created = attrs?[.creationDate] as? Date,
                   now.timeIntervalSince(created) > maxAge {
                    return false
                }
                // Header-only WAVs are 44 bytes.
                if let size = attrs?[.size] as? Int, size <= 44 {
                    return false
                }
                return true
            }
        }.value

        guard !candidates.isEmpty else { return }

        for group in candidates {
            guard let mixURL = group.mix else { continue }
            var job = PipelineJob(
                meetingTitle: "Recovered Recording (\(group.stem))",
                appName: "Unknown",
                mixPath: mixURL,
                appPath: group.app,
                micPath: group.mic,
                micDelay: 0,
            )
            stampTranscriptOutputOptions(on: &job)
            jobs.append(job)
            eventLog.append(jobID: job.id, event: "recovered", from: nil, to: .waiting)
        }
        saveSnapshot()
        logger.info("Recovered \(candidates.count) orphaned recording(s)")
        triggerProcessing()
    }
}
