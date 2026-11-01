import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerNamingSession")

/// Late-confirm and late re-diarization paths — the speaker-naming work that
/// happens after the pipeline already reached `.speakerNamingPending`. Split
/// out of `SpeakerNamingSession.swift` to keep both files under the lint cap.
extension SpeakerNamingSession {
    // MARK: - Late work tracking

    /// Run `work` on a task of its own, tracked under `jobID` until it returns
    /// so `cancelLateWork` can reach it.
    func startLateWork(jobID: UUID, _ work: @escaping () async -> Void) {
        let token = UUID()
        lateWork[jobID, default: [:]][token] = Task {
            await work()
            lateWork[jobID]?[token] = nil
            if lateWork[jobID]?.isEmpty == true { lateWork[jobID] = nil }
        }
    }

    /// Cancel every late-naming task still running for `jobID`. Called when
    /// the job is removed or cancelled. The tasks still re-check the job after
    /// each await, because a step that ignores cancellation returns all the
    /// same.
    func cancelLateWork(jobID: UUID) {
        lateWork.removeValue(forKey: jobID)?.values.forEach { $0.cancel() }
    }

    // MARK: - Protocol for accepted auto-names

    /// Takes the delegate as a strong parameter (captured by the spawning Task
    /// in `acceptAutoNames`) so the queue stays alive across the LLM-generation
    /// await; see `delegate` for the keep-alive rationale. Internal (not
    /// private) because `acceptAutoNames` in SpeakerNamingSession.swift starts
    /// it.
    func generateProtocolForExistingJob(
        jobID: UUID, delegate: any SpeakerNamingSessionDelegate,
    ) async {
        // A job that is gone needs no transition. Anything else must reach a
        // terminal state on every exit: `acceptAutoNames` has already deleted
        // the naming sidecars by the time we get here, so bailing out without a
        // transition would strand the job in `.speakerNamingPending` with
        // nothing left to name — the naming window would keep reopening on an
        // empty placeholder, and the next launch would drop the job with no
        // protocol ever written.
        guard let job = delegate.job(withID: jobID) else { return }
        guard let transcriptPath = job.transcriptPath,
              let transcript = try? String(contentsOf: transcriptPath, encoding: .utf8)
        else {
            // Reachable when the transcript was moved or deleted between the
            // pipeline writing it and the user resolving naming: the caller's
            // readiness probe only checks that `transcriptPath` is non-nil.
            // Matched by /v1 clients and persisted jobs; keep the text stable.
            delegate.addWarning(id: jobID, "Protocol not generated — transcript file is missing")
            finishIfUnresolved(jobID: jobID, delegate: delegate)
            return
        }
        do {
            try await delegate.generateProtocol(
                jobID: jobID,
                transcript: transcript,
                title: job.meetingTitle,
                // Beside the transcript it is made from, which is the rule the
                // protocol-only resume uses too.
                protocolsDir: transcriptPath.deletingLastPathComponent(),
            )
        } catch {
            // Cancelled with its job, which is then gone and needs no
            // transition.
            return
        }
        finishIfUnresolved(jobID: jobID, delegate: delegate)
    }

    /// Move a job to `.done` unless something already advanced it. Accepts
    /// `.speakerNamingPending` as well as `.generatingProtocol` because the
    /// generation call can return before its own `.generatingProtocol`
    /// transition — it guards on the protocol factory, which can go nil between
    /// the readiness probe and the call. Both shapes leave the job pending, and
    /// pending with its sidecars deleted is unrecoverable.
    private func finishIfUnresolved(jobID: UUID, delegate: any SpeakerNamingSessionDelegate) {
        let state = delegate.job(withID: jobID)?.state
        if state == .generatingProtocol || state == .speakerNamingPending {
            delegate.updateJobState(id: jobID, to: .done)
        }
    }

    // MARK: - Late re-apply speaker names

    /// Late-confirm path: read the saved transcript, replace generic speaker
    /// labels with user-provided names, update the matcher DB, regenerate the
    /// protocol with the correct names.
    func reapplySpeakerNames(jobID: UUID, mapping: [String: String]) async {
        // Strong per-flow delegate capture (see `delegate`): keeps the queue
        // alive until the transcript rewrite, protocol regeneration, and the
        // final `.done` all land, even if the controller swaps queues mid-flow.
        guard let delegate,
              let namingData = speakerNamingDataByJob[jobID],
              let job = delegate.job(withID: jobID) else { return }

        let slug = job.namingSlug

        // Update speaker matcher DB
        let matcher = speakerMatcherFactory()
        var fullMapping = namingData.mapping
        for (label, name) in mapping where !name.isEmpty {
            fullMapping[label] = name
        }
        // Hold back what an echo-affected recording must not teach the app. The
        // filter sits here rather than in `updateDB` because this is the only
        // place a job's embeddings reach the database, and it is the last point
        // at which the track each one came from is still readable — `updateDB`
        // sees labels but never parses them. Dropping an entry is enough to
        // suppress the write: `updateDB` skips any label with no embedding.
        //
        // Note this filters `fullMapping`'s effect, not `fullMapping` itself.
        // The transcript rewrite below still uses every name the user gave, so a
        // quarantined speaker is still named in the transcript — only the voice
        // is not memorised.
        let admissible = EchoEmbeddingQuarantine.admissible(
            namingData.embeddings,
            verdict: EchoVerdict(job.echo),
            isDualSource: namingData.isDualSource,
            provenSilentAppTrack: micSpeakersOverSilence(namingData, of: job),
        )
        if admissible.count != namingData.embeddings.count {
            let held = namingData.embeddings.count - admissible.count
            logger.info("echo_quarantine held=\(held, privacy: .public) of=\(namingData.embeddings.count, privacy: .public)")
        }
        delegate.updateSpeakerDB(
            matcher: matcher,
            mapping: fullMapping,
            embeddings: admissible,
            // Thread the per-speaker speaking times so the matcher's
            // centroid-quality filter (short segments stay as fallback samples,
            // long ones seed the centroid) sees real durations.
            speakingTimes: namingData.speakingTimes,
            jobID: jobID,
        )

        if let transcriptPath = job.transcriptPath {
            do {
                var transcript = try String(contentsOf: transcriptPath, encoding: .utf8)
                // Format from `TimestampedSegment.formattedLine`: `[MM:SS] Speaker: text`.
                // Anchor the replace on `] ` + label + `:` so we hit the speaker
                // slot and not a substring inside the spoken text.
                for (label, name) in mapping where !name.isEmpty {
                    transcript = transcript.replacingOccurrences(of: "] \(label):", with: "] \(name):")
                    if let autoName = namingData.mapping[label], autoName != label, autoName != name {
                        transcript = transcript.replacingOccurrences(of: "] \(autoName):", with: "] \(name):")
                    }
                }
                try transcript.write(to: transcriptPath, atomically: true, encoding: .utf8)
                // Re-applying speaker names rewrites the transcript — keep it
                // owner-only (the original save in saveTranscript already is).
                try FileManager.default.restrictToOwner(transcriptPath)
                // Dropped here, not after the protocol call below, so that the
                // naming sidecar still being on disk means exactly one thing:
                // this rewrite did not happen. `ProtocolResumePolicy` reads it
                // that way, because the state hop into `.generatingProtocol` is
                // synchronous and therefore says nothing about the transcript.
                // Idempotent, and the unconditional call at the end still covers
                // the paths that never reach this line.
                removeNamingData(jobID: jobID, slug: slug)

                try await delegate.generateProtocol(
                    jobID: jobID,
                    transcript: transcript,
                    title: job.meetingTitle,
                    // Beside the transcript it is made from, which is the rule
                    // the protocol-only resume uses too. The session's own
                    // folder is wherever the setting points now, which after a
                    // repoint is not where this `.txt` is.
                    protocolsDir: transcriptPath.deletingLastPathComponent(),
                )
            } catch is CancellationError {
                // Cancelled with its job: nothing failed, and there is no job
                // left to finish.
                return
            } catch {
                logger.error("Failed to re-apply speaker names: \(error.localizedDescription, privacy: .public)")
            }
        }

        removeNamingData(jobID: jobID, slug: slug)
        delegate.updateJobState(id: jobID, to: .done)
    }

    /// Microphone speakers who did their talking while the app track carried
    /// nothing, and so cannot have been bleed.
    ///
    /// Without this an affected recording teaches the app nothing at all —
    /// including the voice of the person sitting at the machine, whose own
    /// track was never in doubt. The evidence comes from the persisted app
    /// sidecar, the same file late re-diarization reads; if it is missing, the
    /// answer is "no evidence", and the whole microphone track stays held.
    private func micSpeakersOverSilence(
        _ namingData: SpeakerNamingData, of job: PipelineJob,
    ) -> Set<String> {
        // Both halves of the precondition `admissible` applies, so the two
        // cannot drift: a single-source job has no app track to clear anyone
        // with, and probing for one costs folder stats, an audio open and a
        // per-segment RMS for a result that is then discarded.
        guard EchoVerdict(job.echo) == .affected,
              namingData.isDualSource,
              let slug = job.namingSlug,
              let recordingsDir = sidecarDir(
                  of: job, slug: slug, holdingAnyOf: [SpeakerNamingStore.appTrackSuffix],
              )
        else { return [] }
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: namingData.segments,
            appTrackURL: recordingsDir
                .appendingPathComponent("\(slug)\(SpeakerNamingStore.appTrackSuffix)"),
        )
        if !proven.isEmpty {
            logger.info("echo_quarantine_admitted count=\(proven.count, privacy: .public) spoke only over a silent app track")
        }
        return proven
    }

    // MARK: - Late Re-diarization

    /// Start a late re-diarization. The job leaves `.speakerNamingPending` here,
    /// synchronously, for the same reason a confirm does: the dialog closes on
    /// the change, and a second answer for the job is refused rather than
    /// starting a second flow. The re-run puts it back when it finishes or
    /// fails. One that cannot start at all (no audio, no diarizer) is found
    /// out first, changes nothing, and returns why.
    /// Internal (not private) because `completeSpeakerNaming` in
    /// SpeakerNamingSession.swift calls it.
    func startRerun(jobID: UUID, speakerCount: Int, mode: DiarizerMode?) -> SpeakerNamingRefusal? {
        let plan: LateRerunPlan
        do {
            plan = try lateRerunPlan(jobID: jobID, mode: mode)
        } catch {
            return error
        }
        delegate?.updateJobState(id: jobID, to: .diarizing)
        startLateWork(jobID: jobID) { await self.lateDiarization(plan, speakerCount: speakerCount) }
        return nil
    }

    /// What a late re-run works from, resolved before the job leaves
    /// `.speakerNamingPending` so that a re-run which cannot start changes
    /// nothing: no stage transition, no closing and re-opening of the dialog.
    struct LateRerunPlan {
        /// Held strongly from the moment `startRerun` moves the job to
        /// `.diarizing` (the per-flow capture `delegate` describes), so the
        /// re-run always gets to put the job back. Resolved only on the task's
        /// first turn, a queue gone by then left the job in `.diarizing` for
        /// good, and the next launch ran it as a full pipeline.
        let delegate: any SpeakerNamingSessionDelegate
        let job: PipelineJob
        let namingData: SpeakerNamingData
        let slug: String
        let recordingsDir: URL
        let diarizer: any DiarizationProvider
    }

    /// The plan for re-diarizing `jobID`. Throws, and logs, why there is none:
    /// the dialog tells the user rather than wait for a re-run that never
    /// started.
    ///
    /// `mode` optionally overrides the diarizer mode. `nil` keeps the current
    /// global setting via `diarizationFactory()`. Non-nil uses
    /// `diarizationFactoryWithMode` to instantiate a one-off diarizer in the
    /// requested mode, so the user can recover from a wrong-mode-at-recording
    /// time without leaving the naming dialog.
    func lateRerunPlan(jobID: UUID, mode: DiarizerMode?) throws(SpeakerNamingRefusal) -> LateRerunPlan {
        guard let delegate,
              let namingData = speakerNamingDataByJob[jobID],
              let job = delegate.job(withID: jobID),
              let slug = job.namingSlug,
              let recordingsDir = lateRunRecordingsDir(
                  of: job, slug: slug, isDualSource: namingData.isDualSource,
              )
        else {
            logger.warning("Cannot re-diarize: audio not found in any folder this job recorded")
            throw .rerunAudioMissing
        }
        // After the audio, which is cheap to check and the one the user cannot
        // fix by choosing another mode.
        guard let diarizer = diarizationFactory.map({ resolveLateDiarizer(mode: mode, defaultFactory: $0) }),
              diarizer.isAvailable
        else {
            logger.warning("Diarization not available for late re-run")
            throw .rerunDiarizerUnavailable
        }
        return LateRerunPlan(
            delegate: delegate, job: job, namingData: namingData,
            slug: slug, recordingsDir: recordingsDir, diarizer: diarizer,
        )
    }

    /// Re-run diarization from persisted 16kHz audio after pipeline completed.
    /// `speakerCount` is the target count (ignored by the Sortformer and
    /// Nemotron 3 modes).
    func lateDiarization(_ plan: LateRerunPlan, speakerCount: Int) async {
        let jobID = plan.job.id
        // Strong per-flow delegate capture (see `delegate`), taken with the
        // plan: keeps the queue alive across the re-diarization await so the
        // rewrite, metadata, and the return to `.speakerNamingPending` land
        // even if the controller swaps queues mid-flow.
        let delegate = plan.delegate
        // `startRerun` put the job in `.diarizing`; one that left it before
        // this task first ran (cancelled, say) is no longer this flow's.
        guard isStillRerunning(jobID: jobID, delegate: delegate) else { return }

        do {
            let title = plan.job.meetingTitle
            let run = try await runLateDiarization(
                diarizer: plan.diarizer,
                recording: (dir: plan.recordingsDir, slug: plan.slug, jobID: jobID, micDelay: plan.job.micDelay),
                isDualSource: plan.namingData.isDualSource,
                speakerCount: speakerCount, title: title,
            )
            // The job can be cancelled while the diarizer runs, and a diarizer
            // that ignores cancellation still returns. Everything below writes
            // for this job: naming data, its sidecar, the transcript, and its
            // return to `.speakerNamingPending`. Writing it for a job that is
            // gone leaves an orphaned entry and file behind, and for a job
            // that has moved on (to `.done`, say) it would drag the job back
            // into the dialog. Only the state this flow put it in is its own.
            guard isStillRerunning(jobID: jobID, delegate: delegate) else { return }

            // Dual-track always yields a combined result (the merge, or the
            // app-only / mic-only single-track fallback); single-source sets it
            // directly. Only a both-track failure throws before a run exists.
            guard let combined = run.combined else { throw DiarizationError.notAvailable }
            guard let newNamingData = buildNamingData(
                jobID: jobID, title: title,
                diarization: combined, prior: plan.namingData,
            ) else {
                logger.warning("Late re-diarization produced no embeddings")
                returnToNaming(jobID: jobID, delegate: delegate, failure: .rerunFoundNoVoices)
                return
            }

            speakerNamingDataByJob[jobID] = newNamingData
            let saved = saveNamingData(
                newNamingData, slug: plan.slug, in: plan.recordingsDir.deletingLastPathComponent(),
            )
            // Re-segment the saved transcript to match the fresh diarization.
            // A re-run can change the speaker count and segment boundaries, but
            // the late-confirm path only renames labels already present in the
            // .txt — so without this rewrite any speakers the re-run adds never
            // reach the transcript. Mirrors the batch path, which renders the
            // transcript from its final run.
            rewriteTranscriptFromLateRun(
                run: run, autoNames: newNamingData.mapping,
                isDualSource: plan.namingData.isDualSource, slug: plan.slug, jobID: jobID,
            )
            // Track which mode produced this fresh naming data so the next
            // dialog open initialises the mode picker correctly.
            // `setNamingMetadata` re-resolves the job by id, so the diarization
            // await outliving another job's `completedJobLifetime` eviction
            // (which shifts the queue's array) can't corrupt a stale index.
            delegate.setNamingMetadata(
                jobID: jobID, slug: plan.slug, usedDiarizerMode: plan.diarizer.mode,
                // The folder this run wrote to, and only if it landed. For a
                // job that recorded none that is the queue's own folder, which
                // nothing had recorded yet.
                wroteSidecarsIn: saved ? plan.recordingsDir.deletingLastPathComponent() : nil,
            )

            returnToNaming(jobID: jobID, delegate: delegate)

            // Same hand-off as the first pass, so the re-run's task ends here
            // rather than staying alive until the handler answers.
            invokeHandler(jobID: jobID, data: newNamingData)
        } catch {
            // A cancelled job ends here when its diarizer honours cancellation.
            // Nothing failed, and there is no job left to roll back.
            guard isStillRerunning(jobID: jobID, delegate: delegate) else { return }
            logger.error("Late re-diarization failed: \(error.localizedDescription, privacy: .public)")
            returnToNaming(jobID: jobID, delegate: delegate, failure: .rerunFailed)
        }
    }

    /// Whether the job is still in the state a re-run put it in. Not merely
    /// still there: a re-run that outlived its moment must not move a job
    /// that has since gone on to something else.
    private func isStillRerunning(jobID: UUID, delegate: any SpeakerNamingSessionDelegate) -> Bool {
        delegate.isStillQueued(jobID) && delegate.job(withID: jobID)?.state == .diarizing
    }

    /// Put a re-run's job back in front of the user, with fresh naming or the
    /// naming it had when the re-run produced nothing to use. Only from
    /// `.diarizing`, for the reason in `isStillRerunning`. The dialog is
    /// offered again because starting the re-run closed it.
    /// `failure` says why the re-run came back with nothing, for the dialog it
    /// reopens; nil after a re-run that produced fresh naming.
    private func returnToNaming(
        jobID: UUID, delegate: any SpeakerNamingSessionDelegate, failure: SpeakerNamingRefusal? = nil,
    ) {
        guard isStillRerunning(jobID: jobID, delegate: delegate) else { return }
        lateRerunFailures[jobID] = failure
        delegate.updateJobState(id: jobID, to: .speakerNamingPending)
        NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)
    }

    /// Resolve the diarizer for a late re-run: a mode override uses the
    /// mode-aware factory (falling back to `defaultFactory` plus a warning when
    /// none is wired); `nil` keeps the current global setting.
    private func resolveLateDiarizer(
        mode: DiarizerMode?, defaultFactory: () -> any DiarizationProvider,
    ) -> any DiarizationProvider {
        if let mode, let factory = diarizationFactoryWithMode {
            return factory(mode)
        }
        if let mode {
            logger.warning(
                "Late re-diarize requested mode=\(mode.rawValue, privacy: .public) but no mode-aware factory wired; falling back to global setting",
            )
        }
        return defaultFactory()
    }

    /// Re-diarize the persisted 16 kHz audio for a job. Dispatches between
    /// dual-source (separate app + mic tracks merged, via the shared queue
    /// helper) and single-source (mix only).
    /// The recordings folder a late re-run reads from, or nil when none of the
    /// folders this job recorded holds its audio.
    ///
    /// What the run actually opens: the two tracks for a dual-source job, which
    /// the diarization degrades to whichever one survived, and the mix
    /// otherwise.
    private func lateRunRecordingsDir(
        of job: PipelineJob, slug: String, isDualSource: Bool,
    ) -> URL? {
        sidecarDir(
            of: job, slug: slug,
            holdingAnyOf: isDualSource
                ? [SpeakerNamingStore.appTrackSuffix, SpeakerNamingStore.micTrackSuffix]
                : [SpeakerNamingStore.mixSuffix],
        )
    }

    private func runLateDiarization(
        diarizer: any DiarizationProvider,
        recording: (dir: URL, slug: String, jobID: UUID, micDelay: TimeInterval),
        isDualSource: Bool,
        speakerCount: Int,
        title: String,
    ) async throws -> DiarizationRun {
        let (recordingsDir, slug, jobID, micDelay) = recording
        if isDualSource {
            // Mirror the batch path's single-track fallback: a silent/failing
            // track must degrade to the unprefixed surviving-track diarization
            // (app-only on mic failure, mic-only on app failure), not throw (a
            // no-op re-run) or emit prefixed keys the persisted single-track
            // transcript can't match. The weak var still resolves here
            // because `lateDiarization`'s strong per-flow capture keeps the
            // queue alive; the guard is defensive for any future non-flow
            // caller → `notAvailable` rolls back to `.speakerNamingPending`.
            guard let delegate else { throw DiarizationError.notAvailable }
            return try await delegate.runDualTrackDiarization(
                diarizeProcess: diarizer,
                tracks: (
                    app: recordingsDir.appendingPathComponent("\(slug)_app_16k.wav"),
                    mic: recordingsDir.appendingPathComponent("\(slug)_mic_16k.wav"),
                    micDelay: micDelay,
                    viability: delegate.job(withID: jobID)?.trackViability,
                ),
                speakerCount: speakerCount, title: title, jobID: jobID,
            )
        }
        let mix16k = recordingsDir.appendingPathComponent("\(slug)_16k.wav")
        let diarization = try await diarizer.run(
            audioPath: mix16k, numSpeakers: speakerCount, meetingTitle: title,
        )
        return DiarizationRun(app: nil, mic: nil, combined: diarization)
    }

    /// Build SpeakerNamingData from fresh diarization, reusing context from prior naming data.
    private func buildNamingData(
        jobID: UUID, title: String,
        diarization: DiarizationResult, prior: SpeakerNamingData,
    ) -> SpeakerNamingData? {
        guard let embeddings = diarization.embeddings else { return nil }

        let matcher = speakerMatcherFactory()
        var autoNames = matcher.match(embeddings: embeddings)
        if !prior.participants.isEmpty {
            autoNames = SpeakerMatcher.preMatchParticipants(
                mapping: autoNames,
                speakingTimes: diarization.speakingTimes,
                participants: prior.participants,
            )
        }

        return SpeakerNamingData(
            jobID: jobID, meetingTitle: title, mapping: autoNames,
            speakingTimes: diarization.speakingTimes, embeddings: embeddings,
            audioPath: prior.audioPath,
            segments: diarization.segments.map { seg in
                SpeakerNamingData.Segment(start: seg.start, end: seg.end, speaker: seg.speaker)
            },
            participants: prior.participants, isDualSource: prior.isDualSource,
        )
    }

    /// Rewrite the persisted transcript so its speaker segmentation reflects a
    /// fresh late re-diarization. Re-labels the cached transcript segments
    /// (persisted as `<slug>_segments.json`) against the new run with the new
    /// auto-names. A no-op when the cached segments are missing (older
    /// recordings predating segment persistence) — the late-confirm rename then
    /// falls back to the prior behaviour rather than wiping the transcript.
    private func rewriteTranscriptFromLateRun(
        run: DiarizationRun, autoNames: [String: String],
        isDualSource: Bool, slug: String, jobID: UUID,
    ) {
        guard let job = delegate?.job(withID: jobID),
              let transcriptPath = job.transcriptPath,
              // The folder holding the segments, else the newest the job
              // recorded. A missing segments file has to reach the load below,
              // which warns the user that the re-run's speakers never made it
              // into the transcript; disappearing in this guard would make that
              // re-run look like it worked.
              let recordingsDir = sidecarDir(
                  of: job, slug: slug, holdingAnyOf: [SpeakerNamingStore.segmentsSuffix],
              )
              ?? recordingsDir(of: job)
        else { return }
        guard let cachedSegments = loadCachedSegments(dir: recordingsDir, slug: slug) else {
            logger.warning("Late re-diarization: no persisted transcript segments — speaker labels not re-segmented")
            // Don't let the re-run silently appear to succeed: an older recording
            // (predating segment persistence) can't be re-segmented, so any
            // speakers the re-run added won't reach the transcript.
            delegate?.addWarning(
                id: jobID,
                "This recording has no saved transcript segments, so the re-run's speaker changes could not be applied to the transcript",
            )
            return
        }
        // The rebuild renders from the cached segments, which never carried the
        // recording-level note, so the rendering is handed it again. `note` has
        // no default, so this caller cannot forget it the way a rule about
        // write sites could.
        guard let delegate, let rebuilt = delegate.renderLabeledTranscript(
            run: run, cachedSegments: cachedSegments,
            isDualSource: isDualSource, autoNames: autoNames,
            note: delegate.job(withID: jobID)?.trackViability?.transcriptNote,
        ) else { return }
        do {
            try rebuilt.write(to: transcriptPath, atomically: true, encoding: .utf8)
            // Keep the rewritten transcript owner-only, matching the original save.
            try FileManager.default.restrictToOwner(transcriptPath)
        } catch {
            // Error left redacted: the write target is `<title>_transcript.txt`,
            // so a file-write error description would leak the meeting title.
            logger.error("Late re-diarization: failed to rewrite transcript: \(error.localizedDescription)")
        }
    }

    /// Load the transcript segments persisted by `generateAndSaveProtocol`
    /// (`<slug>_segments.json`). Returns nil when the file is absent or
    /// undecodable.
    private func loadCachedSegments(dir: URL, slug: String)
        -> [TimestampedSegment]? { // swiftlint:disable:this discouraged_optional_collection
        let segPath = dir.appendingPathComponent("\(slug)_segments.json")
        guard let data = try? Data(contentsOf: segPath),
              let segments = try? JSONDecoder().decode([TimestampedSegment].self, from: data) else {
            return nil
        }
        return segments
    }
}
