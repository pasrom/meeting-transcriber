// swiftlint:disable file_length
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

/// Pipeline-stage execution methods, split out of `PipelineQueue.swift` to
/// shrink the primary class body (first slice of an ongoing reduction). An
/// extension of a globally `@MainActor`-isolated type inherits that isolation,
/// so the moved methods need no explicit annotation. Pure move; no behavior
/// change. `file_length` is suppressed here just as it is on
/// `PipelineQueue.swift`; a later slice trims both.
extension PipelineQueue {
    /// Process the first waiting job through the full pipeline:
    /// resample → transcribe → (diarize) → save transcript → generate protocol → save protocol.
    /// Immutable per-job inputs threaded through the pipeline stages.
    private struct JobContext {
        let jobID: UUID
        let shortID: String
        let title: String
        let mixPath: URL?
        let appPath: URL?
        let micPath: URL?
        let micDelay: TimeInterval
        let participants: [String]
        /// Persisted-file basename, computed once from title + jobID so the
        /// diarization and protocol stages agree on the same `\(slug)_16k.wav`.
        let slug: String
    }

    /// Output of the transcription stage, consumed by diarization + protocol save.
    private struct TranscriptionOutput {
        let transcript: String
        /// Segments cached for diarization reuse (avoids double transcription).
        let cachedSegments: [TimestampedSegment]? // swiftlint:disable:this discouraged_optional_collection
        let isDualSource: Bool
    }

    /// Typed errors thrown by the pipeline stages.
    enum PipelineError: LocalizedError {
        case missingMixPath
        case noMixAudioForDiarization

        var errorDescription: String? {
            switch self {
            case .missingMixPath: "Single-source job missing mixPath"
            case .noMixAudioForDiarization: "No mix audio available for diarization"
            }
        }
    }

    /// Thin orchestrator: take the next waiting job and run it through the
    /// pipeline — transcribe → diarize → generate protocol → done.
    func processNext() async {
        guard let index = jobs.firstIndex(where: { $0.state == .waiting }) else {
            isProcessing = false
            return
        }
        guard let engine, let outputDir else {
            logger.warning("Processing dependencies not configured — skipping")
            isProcessing = false
            return
        }
        let job = jobs[index]
        let ctx = JobContext(
            jobID: job.id,
            shortID: job.shortID,
            title: job.meetingTitle,
            mixPath: job.mixPath,
            appPath: job.appPath,
            micPath: job.micPath,
            micDelay: job.micDelay,
            participants: job.participants,
            slug: Self.namingSlug(title: job.meetingTitle, jobID: job.id),
        )

        do {
            // Temp directory for intermediate 16kHz files, cleaned up on any exit.
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pipeline_\(ctx.jobID.uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            let transcription = try await transcribe(ctx, engine: engine, workDir: workDir)

            guard !transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Compute input RMS only on the failure path — loading the whole
                // mix file is expensive (~MB-per-minute) and we only need it when
                // diagnosing why transcription produced nothing. Paired imports
                // without a real mix file report NaN (RMS unavailable).
                let inputRMS = ctx.mixPath.flatMap { AudioMixer.rmsDecibels(forFileAt: $0) } ?? .nan
                logger.warning(
                    "[\(ctx.shortID, privacy: .public)] transcription_empty inputRMSdBFS=\(inputRMS, privacy: .public). Likely silent input or ASR misconfiguration — check microphone level and engine settings.",
                )
                updateJobState(id: ctx.jobID, to: .error, error: "Empty transcript")
                isProcessing = false
                triggerProcessing()
                return
            }

            let finalTranscript = try await diarize(
                transcription, ctx: ctx, engine: engine,
                workDir: workDir, outputDir: outputDir,
            )

            try await generateAndSaveProtocol(
                finalTranscript: finalTranscript, transcription: transcription,
                ctx: ctx, workDir: workDir, outputDir: outputDir,
            )
        } catch is CancellationError {
            stopElapsedTimer()
            logger.info("Job \(ctx.jobID) cancelled")
            // Job already removed by cancelJob()
        } catch {
            stopElapsedTimer()
            if cancelledJobIDs.remove(ctx.jobID) != nil {
                logger.info("Job \(ctx.jobID) cancelled")
            } else {
                logger.error("Pipeline error for job \(ctx.jobID): \(error.localizedDescription, privacy: .public)")
                updateJobState(id: ctx.jobID, to: .error, error: error.localizedDescription)
            }
        }

        isProcessing = false
        triggerProcessing()
    }

    // MARK: - Pipeline stages

    /// Stage 1 — resample source audio to 16 kHz and transcribe. Dual-source
    /// tracks are transcribed separately and merged; single-source optionally
    /// runs VAD silence-trimming with timestamp remapping. Caches segments for
    /// diarization reuse.
    private func transcribe(
        _ ctx: JobContext, engine: any TranscribingEngine, workDir: URL,
    ) async throws -> TranscriptionOutput {
        updateJobState(id: ctx.jobID, to: .transcribing)
        startElapsedTimer()
        logger.info("[\(ctx.shortID, privacy: .public)] transcription_start title=\(ctx.title, privacy: .private)")

        let transcript: String
        // Segments cached for potential diarization reuse (avoids double transcription)
        var cachedSegments: [TimestampedSegment]? // swiftlint:disable:this discouraged_optional_collection
        let isDualSource = ctx.appPath != nil && ctx.micPath != nil
        if let appAudioPath = ctx.appPath, let micAudioPath = ctx.micPath {
            // Dual-source: resample both tracks to 16kHz concurrently
            let app16k = workDir.appendingPathComponent("app_16k.wav")
            let mic16k = workDir.appendingPathComponent("mic_16k.wav")
            async let appResample: Void = AudioMixer.resampleFile(from: appAudioPath, to: app16k)
            async let micResample: Void = AudioMixer.resampleFile(from: micAudioPath, to: mic16k)
            try await appResample
            try await micResample

            // Transcribe each track separately
            let appSegments = try await engine.transcribeSegments(audioPath: app16k)
            let micSegments = try await engine.transcribeSegments(audioPath: mic16k)

            // Merge dual-source segments
            let segments = DiarizationProcess.mergeDualSourceSegments(
                appSegments: appSegments,
                micSegments: micSegments,
                micDelay: ctx.micDelay,
                micLabel: micLabel,
            )
            cachedSegments = segments
            transcript = segments.map(\.formattedLine).joined(separator: "\n")
        } else {
            // Single-source: resample mix to 16kHz
            guard let mixPath = ctx.mixPath else {
                throw PipelineError.missingMixPath
            }
            let mix16k = workDir.appendingPathComponent("mix_16k.wav")
            try await AudioMixer.resampleFile(from: mixPath, to: mix16k)

            // Optional VAD preprocessing: trim silence before transcription
            var vadMap: VadSegmentMap?
            let transcriptionPath: URL
            if vadConfig != nil, let vadResult = try await preprocessWithVAD(audioPath: mix16k, workDir: workDir) {
                transcriptionPath = vadResult.trimmedPath
                vadMap = vadResult.map
            } else {
                transcriptionPath = mix16k
            }

            // Use transcribeSegments to cache results for diarization
            var segments = try await engine.transcribeSegments(audioPath: transcriptionPath)

            // Remap timestamps back to original timeline if VAD was used
            if let map = vadMap {
                segments = map.remapTimestamps(segments)
            }

            cachedSegments = segments
            transcript = segments.map(\.formattedLine).joined(separator: "\n")
        }

        stopElapsedTimer()

        let segCount = cachedSegments?.count ?? 0
        let totalSecs = cachedSegments?.last?.end ?? 0
        // Stash for stage-timing RTF: diarization/protocol of this job process
        // the same audio length.
        jobAudioSeconds[ctx.jobID] = totalSecs
        logger.info(
            "[\(ctx.shortID, privacy: .public)] transcription_complete segments=\(segCount, privacy: .public) duration=\(totalSecs, privacy: .public)s",
        )

        return TranscriptionOutput(transcript: transcript, cachedSegments: cachedSegments, isDualSource: isDualSource)
    }

    /// Stage 2 — optional speaker diarization. Returns the transcript with
    /// speaker labels applied, or the original transcript unchanged when
    /// diarization is disabled, unavailable, or fails. Drives the speaker-naming
    /// dialog loop and persists naming data + recognition forensics as side
    /// effects.
    private func diarize(
        _ transcription: TranscriptionOutput, ctx: JobContext,
        engine: any TranscribingEngine, workDir: URL, outputDir: URL,
    ) async throws -> String {
        var finalTranscript = transcription.transcript

        guard diarizeEnabled, let diarizationFactory else { return finalTranscript }
        // An engine without per-utterance timestamps (one that emits a single
        // whole-recording segment) can't be diarized — assignSpeakers would
        // collapse the entire meeting onto one speaker. Skip it and tell the
        // user why. Dual-source transcripts keep their per-track Remote/mic
        // labels (set in transcribe()); single-source stays unlabeled.
        guard engine.providesTimestamps else {
            logger.info("[\(ctx.shortID, privacy: .public)] diarization_skipped_no_timestamps")
            addWarning(
                id: ctx.jobID,
                "Speaker diarization needs per-utterance timestamps, which the selected transcription engine doesn't produce — speakers not labeled",
            )
            return finalTranscript
        }
        let diarizeProcess = diarizationFactory()
        guard diarizeProcess.isAvailable else {
            logger.info("[\(ctx.shortID, privacy: .public)] diarization_skipped")
            return finalTranscript
        }

        updateJobState(id: ctx.jobID, to: .diarizing)
        startElapsedTimer()
        let mix16k = try await ensureMixAudio(workDir: workDir, ctx: ctx)

        do {
            let speakerCount = numSpeakers > 0 ? numSpeakers : nil
            let run = try await runDiarization(
                diarizeProcess: diarizeProcess, useDualTrack: transcription.isDualSource,
                speakerCount: speakerCount, workDir: workDir, ctx: ctx,
            )
            // Match against the speaker DB and park the job for the (possibly
            // late) naming dialog. A speaker-count/mode re-run is no longer an
            // in-line loop here; it's driven after the job reaches
            // `.speakerNamingPending` via `completeSpeakerNaming`, so both the
            // interactive UI and the test handler take the same path.
            var autoNames: [String: String] = [:]
            if let currentDiarization = run.combined {
                autoNames = naming.resolveSpeakerNames(
                    diarization: currentDiarization,
                    job: (jobID: ctx.jobID, title: ctx.title, slug: ctx.slug, participants: ctx.participants),
                    diarizeProcess: diarizeProcess, isDualSource: transcription.isDualSource,
                    outputDir: outputDir,
                )
            }

            if let labeled = try await labeledTranscript(
                from: run, autoNames: autoNames, transcription: transcription,
                engine: engine, mix16k: mix16k,
            ) {
                finalTranscript = labeled
            }
            let segCount = run.combined?.segments.count ?? 0
            logger.info("[\(ctx.shortID, privacy: .public)] diarization_complete segments=\(segCount, privacy: .public)")
        } catch {
            logger.warning("[\(ctx.shortID, privacy: .public)] diarization_failed error=\(error.localizedDescription, privacy: .public)")
            addWarning(id: ctx.jobID, "Diarization failed — speakers not identified")
            // Continue with original transcript
        }

        return finalTranscript
    }

    /// Ensure a 16 kHz mix exists for diarization, returning its path. Single
    /// source already resampled it in the transcribe stage; paired imports
    /// without a real `_mix.wav` mix `app + mic` directly into the workdir cache
    /// (no persistent mix file written).
    private func ensureMixAudio(workDir: URL, ctx: JobContext) async throws -> URL {
        let mix16k = workDir.appendingPathComponent("mix_16k.wav")
        guard !FileManager.default.fileExists(atPath: mix16k.path) else { return mix16k }
        if let mixPath = ctx.mixPath, FileManager.default.fileExists(atPath: mixPath.path) {
            try await AudioMixer.resampleFile(from: mixPath, to: mix16k)
        } else if let appAudioPath = ctx.appPath, let micAudioPath = ctx.micPath {
            try AudioMixer.mix(
                appAudioPath: appAudioPath, micAudioPath: micAudioPath,
                outputPath: mix16k, micDelay: ctx.micDelay,
                sampleRate: AudioConstants.targetSampleRate,
            )
        } else {
            throw PipelineError.noMixAudioForDiarization
        }
        return mix16k
    }

    /// Run diarization for one loop iteration. Dual-track diarizes the app and
    /// mic tracks separately and tolerates either track failing (a silent track
    /// on a host without a real input device, or a silent remote side in a solo
    /// meeting) by falling back to the surviving track; the `combined` result is
    /// the prefixed merge, or the single-track fallback, fed into speaker naming.
    /// Single-source diarizes the mix directly.
    private func runDiarization(
        diarizeProcess: any DiarizationProvider, useDualTrack: Bool,
        speakerCount: Int?, workDir: URL, ctx: JobContext,
    ) async throws -> DiarizationRun {
        guard useDualTrack else {
            let diarization = try await diarizeProcess.run(
                audioPath: workDir.appendingPathComponent("mix_16k.wav"),
                numSpeakers: speakerCount, meetingTitle: ctx.title,
            )
            return DiarizationRun(app: nil, mic: nil, combined: diarization)
        }

        return try await runDualTrackDiarization(
            diarizeProcess: diarizeProcess,
            tracks: (
                app: workDir.appendingPathComponent("app_16k.wav"),
                mic: workDir.appendingPathComponent("mic_16k.wav"),
                micDelay: ctx.micDelay,
            ),
            speakerCount: speakerCount, title: ctx.title, jobID: ctx.jobID,
        )
    }

    /// Diarize the app + mic tracks separately, tolerating either track failing
    /// (a silent mic on a host without a real input device, or a silent remote
    /// side in a solo meeting) by falling back to the surviving track; only a
    /// both-track failure propagates. On a single-track fallback the `combined`
    /// result is that track's *unprefixed* diarization, so downstream naming keys
    /// stay consistent with the persisted single-track transcript, rather than the
    /// `R_`/`M_`-prefixed merge. Shared by the batch (`runDiarization`) and the
    /// session's late re-run so the fallback can't diverge between them. Internal
    /// (not private) because it is a `SpeakerNamingSessionDelegate` witness.
    func runDualTrackDiarization(
        diarizeProcess: any DiarizationProvider,
        tracks: (app: URL, mic: URL, micDelay: TimeInterval),
        speakerCount: Int?, title: String, jobID: UUID,
    ) async throws -> DiarizationRun {
        let sid = PipelineJob.shortID(for: jobID)

        var appDiarization: DiarizationResult?
        var appError: (any Error)?
        do {
            appDiarization = try await diarizeProcess.run(
                audioPath: tracks.app, numSpeakers: speakerCount, meetingTitle: title,
            )
        } catch {
            appError = error
        }

        var micDiarization: DiarizationResult?
        var micError: (any Error)?
        do {
            let rawMic = try await diarizeProcess.run(
                audioPath: tracks.mic,
                numSpeakers: nil, // auto-detect local speakers
                meetingTitle: title,
            )
            // Shift the mic diarization onto the app/canonical timeline so it
            // aligns with the mic transcript segments, which
            // `mergeDualSourceSegments` already shifted by `+micDelay`.
            micDiarization = DiarizationProcess.shiftSegments(rawMic, by: tracks.micDelay)
        } catch {
            micError = error
        }

        // Tolerate one silent/failed track and fall back to the other: a silent
        // local mic on a host without a real input device (app-only), or a silent
        // remote side in a solo meeting (mic-only). Each fallback keeps the other
        // track's segments with their raw tag instead of force-matching them; only
        // a both-track failure is a genuine diarization failure that propagates.
        let combined: DiarizationResult
        switch (appDiarization, micDiarization) {
        case let (app?, mic?):
            combined = DiarizationProcess.mergeDualTrackDiarization(appDiarization: app, micDiarization: mic)

        case let (app?, nil):
            logger.warning(
                "[\(sid, privacy: .public)] mic_diarization_failed error=\(micError?.localizedDescription ?? "unknown", privacy: .public) — falling back to app-only diarization",
            )
            addWarning(id: jobID, "Mic track diarization failed — speaker labels reflect remote audio only")
            combined = app

        case let (nil, mic?):
            logger.warning(
                "[\(sid, privacy: .public)] app_diarization_failed error=\(appError?.localizedDescription ?? "unknown", privacy: .public) — falling back to mic-only diarization",
            )
            addWarning(id: jobID, "App track diarization failed — speaker labels reflect local mic only")
            combined = mic

        case (nil, nil):
            logger.warning(
                "[\(sid, privacy: .public)] diarization_failed_both app=\(appError?.localizedDescription ?? "unknown", privacy: .public) mic=\(micError?.localizedDescription ?? "unknown", privacy: .public)",
            )
            throw appError ?? micError ?? DiarizationError.notAvailable
        }
        return DiarizationRun(app: appDiarization, mic: micDiarization, combined: combined)
    }

    /// Apply speaker names to the transcript for whichever topology the run
    /// produced (dual-track, mic-fail app-only fallback, app-fail mic-only
    /// fallback, or single-source), returning the labeled transcript, or `nil`
    /// when no diarization is available, leaving the caller's transcript
    /// unchanged. The topologies share the merge + format tail, applied once here.
    private func labeledTranscript(
        from run: DiarizationRun, autoNames: [String: String],
        transcription: TranscriptionOutput, engine: any TranscribingEngine, mix16k: URL,
    ) async throws -> String? {
        // cachedSegments is set by the transcribe stage in practice; the
        // single-source branch re-transcribes defensively if it's somehow nil.
        let cachedSegments: [TimestampedSegment]
        if let cached = transcription.cachedSegments {
            cachedSegments = cached
        } else if transcription.isDualSource {
            return nil
        } else {
            cachedSegments = try await engine.transcribeSegments(audioPath: mix16k)
        }
        return renderLabeledTranscript(
            run: run, cachedSegments: cachedSegments,
            isDualSource: transcription.isDualSource, autoNames: autoNames,
        )
    }

    /// Render the speaker-labeled transcript text from a diarization run +
    /// transcript segments: pick the topology, assign speakers, merge
    /// consecutive blocks, and format. Shared by the batch path
    /// (`labeledTranscript`) and the late re-diarization rewrite
    /// (the session's `rewriteTranscriptFromLateRun`) so both re-segment
    /// identically. Returns nil when the run carries no usable diarization.
    /// Internal (not private) because it is a `SpeakerNamingSessionDelegate`
    /// witness.
    func renderLabeledTranscript(
        run: DiarizationRun, cachedSegments: [TimestampedSegment],
        isDualSource: Bool, autoNames: [String: String],
    ) -> String? {
        let topology: DiarizationProcess.LabelingTopology?
        if isDualSource, let appDiar = run.app, let micDiar = run.mic {
            topology = .dualTrack(cached: cachedSegments, micLabel: micLabel, app: appDiar, mic: micDiar)
        } else if isDualSource, let appDiar = run.app {
            // Mic diarization failed (silent track / no input device). Keep the
            // mic transcript with its raw `micLabel` — better than emitting
            // "speakers not identified" on a recording with good remote audio.
            topology = .dualTrackAppOnly(cached: cachedSegments, micLabel: micLabel, app: appDiar)
        } else if isDualSource, let micDiar = run.mic {
            // App diarization failed (silent remote side / solo meeting). Keep the
            // app transcript with its raw `Remote` tag and diarize the mic track —
            // better than emitting "speakers not identified" on a recording with
            // good local audio. Mirror of the app-only fallback above.
            topology = .dualTrackMicOnly(cached: cachedSegments, micLabel: micLabel, mic: micDiar)
        } else if let combined = run.combined {
            topology = .single(segments: cachedSegments, diarization: combined)
        } else {
            return nil
        }
        guard let topology else { return nil }
        let labeled = DiarizationProcess.labelSegments(topology, autoNames: autoNames)
        return DiarizationProcess.mergeConsecutiveSpeakers(labeled).map(\.formattedLine).joined(separator: "\n")
    }

    /// Stage 3 — persist the transcript + audio, run protocol generation
    /// (unless speaker naming is still pending), and transition the job to its
    /// terminal state.
    private func generateAndSaveProtocol(
        finalTranscript: String, transcription: TranscriptionOutput,
        ctx: JobContext, workDir: URL, outputDir: URL,
    ) async throws {
        // --- Save Transcript & Audio (always) ---
        let protocolsDir = outputDir.appendingPathComponent("protocols")
        let txtPath = try ProtocolGenerator.saveTranscript(finalTranscript, title: ctx.title, dir: protocolsDir)
        logger.info("[\(ctx.shortID, privacy: .public)] transcript_saved file=\(txtPath.lastPathComponent, privacy: .private)")

        if let idx = jobs.firstIndex(where: { $0.id == ctx.jobID }) {
            jobs[idx].transcriptPath = txtPath
            jobs[idx].namingSlug = ctx.slug
        }

        let recordingsDir = outputDir.appendingPathComponent("recordings")
        Self.copyAudioToOutput(
            mixPath: ctx.mixPath, appPath: ctx.appPath, micPath: ctx.micPath,
            title: ctx.title, outputDir: recordingsDir,
        )

        // --- Persist 16kHz audio for re-diarization (move instead of copy to avoid double I/O) ---
        try? FileManager.default.moveItem(
            at: workDir.appendingPathComponent("mix_16k.wav"),
            to: recordingsDir.appendingPathComponent("\(ctx.slug)_16k.wav"),
        )

        if transcription.isDualSource {
            for (name, suffix) in [("app_16k.wav", "_app_16k.wav"), ("mic_16k.wav", "_mic_16k.wav")] {
                try? FileManager.default.moveItem(
                    at: workDir.appendingPathComponent(name),
                    to: recordingsDir.appendingPathComponent("\(ctx.slug)\(suffix)"),
                )
            }
        }

        // --- Persist transcript segments for late re-assignment ---
        if let cachedSegments = transcription.cachedSegments {
            let segPath = recordingsDir.appendingPathComponent("\(ctx.slug)_segments.json")
            if let data = try? JSONEncoder().encode(cachedSegments) {
                try? data.write(to: segPath, options: .atomic)
            }
        }

        // --- Protocol Generation (optional) ---
        // Skip when naming is pending — protocol will be generated on
        // confirm (with the right names) or on skip/stale-cleanup (with
        // the current auto-names). Saves an LLM call we'd otherwise
        // have to redo.
        if naming.speakerNamingDataByJob[ctx.jobID] == nil {
            await generateProtocol(
                jobID: ctx.jobID, transcript: finalTranscript, title: ctx.title,
                protocolsDir: protocolsDir,
            )
        }

        stopElapsedTimer()
        if let namingData = naming.speakerNamingDataByJob[ctx.jobID] {
            updateJobState(id: ctx.jobID, to: .speakerNamingPending)
            // Auto-pop the dialog now that the job is in the right state.
            // The window's onAppear guard reads pendingSpeakerNamingJobs,
            // which only includes .speakerNamingPending jobs, so the
            // notification has to come after the transition above.
            NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)
            // Tests drive naming through an injected handler instead of the UI.
            // Re-invoke it here, after the `.speakerNamingPending` transition,
            // mirroring the late-rerun re-invocation, so the test path runs the
            // exact same `completeSpeakerNaming` flow the production UI does
            // (rerun/mode-override/skip cleanup all included) rather than a
            // divergent in-line state machine. The session captures `self`
            // (the session) strongly for the op duration, never the delegate.
            naming.invokeHandler(jobID: ctx.jobID, data: namingData)
        } else {
            updateJobState(id: ctx.jobID, to: .done)
        }
    }

    // MARK: - Protocol generation

    /// Run the LLM protocol generator over a transcript, save the .md file,
    /// stash its path on the job. No-op if no protocol generator is configured.
    /// Used by: main pipeline (if no naming pending) and the session's
    /// reapplySpeakerNames / skipped / stale paths. Internal (not private)
    /// because it is a `SpeakerNamingSessionDelegate` witness.
    func generateProtocol(
        jobID: UUID, transcript: String, title: String, protocolsDir: URL,
    ) async {
        guard let protocolGeneratorFactory, let generator = protocolGeneratorFactory() else {
            return
        }
        let shortID = PipelineJob.shortID(for: jobID)
        do {
            updateJobState(id: jobID, to: .generatingProtocol)
            startElapsedTimer()
            let diarized = transcript.range(
                of: #"\[\w[\w\s]*\]"#, options: .regularExpression,
            ) != nil
            let protocolMD = try await generator.generate(
                transcript: transcript, title: title, diarized: diarized,
            )
            let fullMD = protocolMD + "\n\n---\n\n## Full Transcript\n\n" + transcript
            let mdPath = try ProtocolGenerator.saveProtocol(
                fullMD, title: title, dir: protocolsDir,
            )
            logger.info("[\(shortID, privacy: .public)] protocol_saved file=\(mdPath.lastPathComponent, privacy: .private)")
            if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[idx].protocolPath = mdPath
            }
            stopElapsedTimer()
        } catch {
            logger.warning("[\(shortID, privacy: .public)] protocol_generation_failed error=\(error.localizedDescription, privacy: .public)")
            addWarning(id: jobID, "Protocol generation failed — transcript saved")
            stopElapsedTimer()
        }
    }

    // MARK: - VAD Preprocessing

    /// Run VAD on a 16kHz audio file. Returns trimmed audio path and segment map,
    /// or nil if no speech regions are detected.
    private func preprocessWithVAD(audioPath: URL, workDir: URL) async throws
        -> (trimmedPath: URL, map: VadSegmentMap)? {
        guard let vadConfig else { return nil }

        let vadInstance = vad ?? {
            let v = FluidVAD(threshold: vadConfig.threshold)
            vad = v
            return v
        }()

        let (samples, _) = try await AudioMixer.loadAudioAsFloat32(url: audioPath)
        let map = try await vadInstance.detectSpeech(samples: samples)

        guard !map.segments.isEmpty else {
            logger.info("VAD: no speech detected")
            return nil
        }

        let speechSamples = map.extractSpeechSamples(from: samples)
        guard !speechSamples.isEmpty else { return nil }

        let trimmedPath = workDir.appendingPathComponent("vad_trimmed.wav")
        try AudioMixer.saveWAV(samples: speechSamples, sampleRate: AudioConstants.targetSampleRate, url: trimmedPath)

        let origStr = String(format: "%.1f", map.originalDuration)
        let trimStr = String(format: "%.1f", map.trimmedDuration)
        logger.info("VAD trimmed: \(origStr)s → \(trimStr)s")

        return (trimmedPath, map)
    }

    // MARK: - Audio File Copy

    /// Copy recording audio files to the protocol output directory. Nil
    /// `mixPath` (paired imports without a `_mix.wav` source) → mix slot
    /// is skipped, no persistent mix is written.
    private static func copyAudioToOutput(
        mixPath: URL?, appPath: URL?, micPath: URL?,
        title: String, outputDir: URL,
    ) {
        // Each move below renames-in-place — if two of the three URLs point at
        // the same file, the first move destroys the source for the next one.
        // Loud failure in dev/CI > silent data destruction.
        if let mixStd = mixPath?.standardizedFileURL {
            precondition(
                appPath.map { mixStd != $0.standardizedFileURL } ?? true,
                "copyAudioToOutput: mixPath aliases appPath — would destroy source",
            )
            precondition(
                micPath.map { mixStd != $0.standardizedFileURL } ?? true,
                "copyAudioToOutput: mixPath aliases micPath — would destroy source",
            )
        }

        let accessing = outputDir.startAccessingSecurityScopedResource()
        defer { if accessing { outputDir.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let slug = ProtocolGenerator.filename(title: title, ext: "").dropLast() // remove trailing "."
        let audioPaths: [(URL, String)] = [
            mixPath.map { ($0, "\(slug)\(RecordingFileSuffix.mix)") },
            appPath.map { ($0, "\(slug)\(RecordingFileSuffix.app)") },
            micPath.map { ($0, "\(slug)\(RecordingFileSuffix.mic)") },
        ].compactMap(\.self)

        let outputDirStd = outputDir.standardizedFileURL
        for (src, name) in audioPaths {
            let dst = outputDir.appendingPathComponent(name)
            // Source already in the target dir → move would just rename in place
            // with a fresh `<today_timestamp>_<title>` prefix, which produces an
            // endless compounding-rename loop on every re-import (orphan recovery
            // re-picks the new name on next launch). The file is already at its
            // final home; keep it put.
            if src.deletingLastPathComponent().standardizedFileURL == outputDirStd {
                logger.info("Audio already in output dir, skipping rename: \(src.lastPathComponent, privacy: .private)")
                continue
            }
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.moveItem(at: src, to: dst)
                logger.info("Audio moved: \(name, privacy: .private)")
            } catch {
                // Error left redacted: a file-move CocoaError embeds the
                // meeting-title-derived filename in its description (the same
                // data the sibling .private annotation hides).
                logger.warning("Failed to move audio \(name, privacy: .private): \(error.localizedDescription)")
            }
        }
    }
}
