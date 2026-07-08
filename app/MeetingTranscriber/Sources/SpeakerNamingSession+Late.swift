import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerNamingSession")

/// Late-confirm and late re-diarization paths — the speaker-naming work that
/// happens after the pipeline already reached `.speakerNamingPending`. Split
/// out of `SpeakerNamingSession.swift` to keep both files under the lint cap.
extension SpeakerNamingSession {
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
        delegate.updateSpeakerDB(
            matcher: matcher,
            mapping: fullMapping,
            embeddings: namingData.embeddings,
            // Thread the per-speaker speaking times so the matcher's
            // centroid-quality filter (short segments stay as fallback samples,
            // long ones seed the centroid) sees real durations.
            speakingTimes: namingData.speakingTimes,
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

                if let outputDir {
                    await delegate.generateProtocol(
                        jobID: jobID,
                        transcript: transcript,
                        title: job.meetingTitle,
                        protocolsDir: outputDir.appendingPathComponent("protocols"),
                    )
                }
            } catch {
                logger.error("Failed to re-apply speaker names: \(error.localizedDescription, privacy: .public)")
            }
        }

        removeNamingData(jobID: jobID, slug: slug)
        delegate.updateJobState(id: jobID, to: .done)
    }

    // MARK: - Late Re-diarization

    /// Re-run diarization from persisted 16kHz audio after pipeline completed.
    ///
    /// - Parameters:
    ///   - jobID: the job to re-diarize.
    ///   - speakerCount: target speaker count (ignored by Sortformer mode).
    ///   - mode: optional override for the diarizer mode. `nil` (default)
    ///     keeps the original behaviour — re-instantiate the diarizer with
    ///     the current global setting via `diarizationFactory()`. Non-nil
    ///     uses `diarizationFactoryWithMode` to instantiate a one-off
    ///     diarizer in the requested mode, so the user can recover from a
    ///     wrong-mode-at-recording-time without leaving the naming dialog.
    func lateDiarization(
        jobID: UUID,
        speakerCount: Int,
        mode: DiarizerMode? = nil,
    ) async {
        // Strong per-flow delegate capture (see `delegate`): keeps the queue
        // alive across the re-diarization await so the rewrite, metadata, and
        // the return to `.speakerNamingPending` land even if the controller
        // swaps queues mid-flow.
        guard let delegate,
              let namingData = speakerNamingDataByJob[jobID],
              let job = delegate.job(withID: jobID),
              let diarizationFactory,
              let slug = job.namingSlug,
              let outputDir else {
            logger.warning("Cannot re-diarize: missing data or configuration")
            return
        }

        let recordingsDir = outputDir.appendingPathComponent("recordings")
        let diarizeProcess = resolveLateDiarizer(mode: mode, defaultFactory: diarizationFactory)
        guard diarizeProcess.isAvailable else {
            logger.warning("Diarization not available for late re-run")
            return
        }

        delegate.namingStageDidStart(jobID: jobID)

        do {
            let title = job.meetingTitle
            let run = try await runLateDiarization(
                diarizer: diarizeProcess,
                recording: (dir: recordingsDir, slug: slug, jobID: jobID, micDelay: job.micDelay),
                isDualSource: namingData.isDualSource,
                speakerCount: speakerCount, title: title,
            )
            delegate.namingStageDidEnd()

            // Dual-track always yields a combined result (the merge, or the
            // app-only / mic-only single-track fallback); single-source sets it
            // directly. Only a both-track failure throws before a run exists.
            guard let combined = run.combined else { throw DiarizationError.notAvailable }
            guard let newNamingData = buildNamingData(
                jobID: jobID, title: title,
                diarization: combined, prior: namingData,
            ) else {
                logger.warning("Late re-diarization produced no embeddings")
                delegate.updateJobState(id: jobID, to: .speakerNamingPending)
                return
            }

            speakerNamingDataByJob[jobID] = newNamingData
            saveNamingData(newNamingData, slug: slug)
            // Re-segment the saved transcript to match the fresh diarization.
            // A re-run can change the speaker count and segment boundaries, but
            // the late-confirm path only renames labels already present in the
            // .txt — so without this rewrite any speakers the re-run adds never
            // reach the transcript. Mirrors the batch path, which renders the
            // transcript from its final run.
            rewriteTranscriptFromLateRun(
                run: run, autoNames: newNamingData.mapping,
                isDualSource: namingData.isDualSource, slug: slug, jobID: jobID,
            )
            // Track which mode produced this fresh naming data so the next
            // dialog open initialises the mode picker correctly.
            // `setNamingMetadata` re-resolves the job by id, so the diarization
            // await outliving another job's `completedJobLifetime` eviction
            // (which shifts the queue's array) can't corrupt a stale index.
            delegate.setNamingMetadata(jobID: jobID, slug: nil, usedDiarizerMode: diarizeProcess.mode)

            delegate.updateJobState(id: jobID, to: .speakerNamingPending)
            NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)

            if let handler = speakerNamingHandler {
                let result = await handler(newNamingData)
                completeSpeakerNaming(jobID: jobID, result: result)
            }
        } catch {
            logger.error("Late re-diarization failed: \(error.localizedDescription, privacy: .public)")
            delegate.namingStageDidEnd()
            delegate.updateJobState(id: jobID, to: .speakerNamingPending)
        }
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
        guard let outputDir,
              let transcriptPath = delegate?.job(withID: jobID)?.transcriptPath else { return }
        let recordingsDir = outputDir.appendingPathComponent("recordings")
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
        guard let delegate, let rebuilt = delegate.renderLabeledTranscript(
            run: run, cachedSegments: cachedSegments,
            isDualSource: isDualSource, autoNames: autoNames,
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
