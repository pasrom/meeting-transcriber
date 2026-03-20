// swiftlint:disable file_length
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

@MainActor
@Observable
// swiftlint:disable:next attributes type_body_length
class PipelineQueue {
    private(set) var jobs: [PipelineJob] = []
    private let logDir: URL

    // Dependencies for processing
    let transcriptionEngine: FluidTranscriptionEngine?
    let diarizationFactory: (() -> DiarizationProvider)?
    let protocolGeneratorFactory: (() -> ProtocolGenerating)?
    let outputDir: URL?
    let diarizeEnabled: Bool
    let numSpeakers: Int
    let micLabel: String
    let customVocabulary: [String]
    let speakerMatcherFactory: () -> SpeakerMatcher

    let completedJobLifetime: TimeInterval

    /// Elapsed seconds since the current pipeline stage started.
    private(set) var activeJobElapsed: TimeInterval = 0
    private(set) var isProcessing = false
    private var elapsedTimer: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var cancelledJobIDs = Set<UUID>()

    /// Called when a job completes (success or error) — for notifications
    var onJobStateChange: ((PipelineJob, JobState, JobState) -> Void)?

    // MARK: - Speaker Naming

    /// Data for the speaker naming popup.
    struct SpeakerNamingData {
        let jobID: UUID
        let meetingTitle: String
        let mapping: [String: String] // label → auto-matched name or label
        let speakingTimes: [String: TimeInterval]
        let embeddings: [String: [Float]]
        let audioPath: URL? // 16kHz mix for playback
        let segments: [DiarizationResult.Segment] // for extracting speaker snippets
        let participants: [String] // Teams participant names as suggestions
    }

    /// Result from the speaker naming popup.
    enum SpeakerNamingResult {
        case confirmed([String: String]) // user confirmed with mapping
        case rerun(Int) // re-run diarization with N speakers
        case skipped // user skipped
    }

    /// Set when the pipeline is waiting for the user to name speakers.
    var pendingSpeakerNaming: SpeakerNamingData?
    private var speakerNamingContinuation: CheckedContinuation<SpeakerNamingResult, Never>?

    /// Timeout for the speaker naming popup (seconds). If the user does not respond
    /// within this time, the continuation resumes with `.skipped`.
    static let speakerNamingTimeout: TimeInterval = 120

    /// Called by the UI when the user confirms or skips speaker naming.
    func completeSpeakerNaming(result: SpeakerNamingResult) {
        pendingSpeakerNaming = nil
        // Guard against double-resume: only resume if continuation is still set
        guard let continuation = speakerNamingContinuation else { return }
        speakerNamingContinuation = nil
        continuation.resume(returning: result)
    }

    /// Handler for speaker naming. When set, called instead of the default
    /// continuation-based popup. Receives naming data, returns result.
    /// Used by tests to auto-complete without UI interaction.
    var speakerNamingHandler: ((SpeakerNamingData) async -> SpeakerNamingResult)?

    /// Simple init for skeleton tests and basic queue usage.
    init(logDir: URL? = nil, completedJobLifetime: TimeInterval = 60) {
        self.logDir = logDir ?? AppPaths.ipcDir
        self.transcriptionEngine = nil
        self.diarizationFactory = nil
        self.protocolGeneratorFactory = nil
        self.outputDir = nil
        self.diarizeEnabled = false
        self.numSpeakers = 0
        self.micLabel = "Me"
        self.customVocabulary = []
        self.speakerMatcherFactory = { SpeakerMatcher() }
        self.completedJobLifetime = completedJobLifetime
    }

    /// Full init with all processing dependencies.
    init(
        transcriptionEngine: FluidTranscriptionEngine,
        diarizationFactory: @escaping () -> DiarizationProvider,
        protocolGeneratorFactory: @escaping () -> ProtocolGenerating,
        outputDir: URL,
        logDir: URL? = nil,
        diarizeEnabled: Bool = false,
        numSpeakers: Int = 0,
        micLabel: String = "Me",
        customVocabulary: [String] = [],
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = { SpeakerMatcher() },
        completedJobLifetime: TimeInterval = 60,
    ) {
        self.logDir = logDir ?? AppPaths.ipcDir
        self.transcriptionEngine = transcriptionEngine
        self.diarizationFactory = diarizationFactory
        self.protocolGeneratorFactory = protocolGeneratorFactory
        self.outputDir = outputDir
        self.diarizeEnabled = diarizeEnabled
        self.numSpeakers = numSpeakers
        self.customVocabulary = customVocabulary
        self.micLabel = micLabel
        self.speakerMatcherFactory = speakerMatcherFactory
        self.completedJobLifetime = completedJobLifetime
    }

    var activeJobs: [PipelineJob] {
        jobs.filter { [.transcribing, .diarizing, .generatingProtocol].contains($0.state) }
    }

    var pendingJobs: [PipelineJob] {
        jobs.filter { $0.state == .waiting }
    }

    var completedJobs: [PipelineJob] {
        jobs.filter { $0.state == .done }
    }

    func enqueue(_ job: PipelineJob) {
        jobs.append(job)
        appendLog(jobID: job.id, event: "enqueued", from: nil, to: job.state)
        writeSnapshot()
        logger.info("Enqueued job: \(job.meetingTitle) (\(job.id))")
        triggerProcessing()
    }

    func removeJob(id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            markProcessed(mixPath: jobs[index].mixPath)
            jobs.remove(at: index)
        }
        writeSnapshot()
    }

    /// Cancel a job. Removes waiting/active jobs from the queue and cancels the
    /// processing task if the job is currently active. Done/error jobs are not affected.
    func cancelJob(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let state = jobs[index].state
        switch state {
        case .waiting:
            jobs.remove(at: index)
            writeSnapshot()

        case .transcribing, .diarizing, .generatingProtocol:
            cancelledJobIDs.insert(id)
            processTask?.cancel()
            jobs.remove(at: index)
            writeSnapshot()

        case .done, .error:
            break
        }
    }

    func updateJobState(id: UUID, to newState: JobState, error: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let oldState = jobs[index].state
        jobs[index].state = newState
        if let error { jobs[index].error = error }
        appendLog(jobID: id, event: "state_change", from: oldState, to: newState)
        writeSnapshot()
        onJobStateChange?(jobs[index], oldState, newState)

        if newState == .done || newState == .error {
            markProcessed(mixPath: jobs[index].mixPath)
        }
        if newState == .done {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.completedJobLifetime ?? 60))
                self?.removeJob(id: id)
            }
        }
    }

    func addWarning(id: UUID, _ message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].warnings.append(message)
        writeSnapshot()
    }

    /// Reset the elapsed timer for a new pipeline stage.
    private func startElapsedTimer() {
        elapsedTimer?.cancel()
        activeJobElapsed = 0
        elapsedTimer = Task { [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let elapsed = ContinuousClock.now - start
                self?.activeJobElapsed = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
            }
        }
    }

    /// Stop the elapsed timer.
    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }

    // MARK: - Processing

    /// Bundles transcription results for downstream pipeline stages.
    private struct TranscriptionOutput {
        let transcript: String
        let segments: [TimestampedSegment]? // swiftlint:disable:this discouraged_optional_collection
        let isDualSource: Bool
    }

    /// Kick off processing if not already running and there are waiting jobs.
    private func triggerProcessing() {
        guard !isProcessing else { return }
        guard pendingJobs.first != nil else { return }
        isProcessing = true
        processTask = Task { [weak self] in
            await self?.processNext()
        }
    }

    /// Process the first waiting job through the full pipeline:
    /// resample → transcribe → (diarize) → save transcript → generate protocol → save protocol.
    func processNext() async {
        guard let index = jobs.firstIndex(where: { $0.state == .waiting }) else {
            isProcessing = false
            return
        }
        guard let transcriptionEngine, let protocolGeneratorFactory, let outputDir else {
            logger.warning("Processing dependencies not configured — skipping")
            isProcessing = false
            return
        }
        let job = jobs[index]

        do {
            // Create a temp directory for intermediate 16kHz files
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pipeline_\(job.id.uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            // --- Transcription ---
            updateJobState(id: job.id, to: .transcribing)
            startElapsedTimer()
            let output = try await transcribe(job: job, engine: transcriptionEngine, workDir: workDir)
            stopElapsedTimer()

            guard !output.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                updateJobState(id: job.id, to: .error, error: "Empty transcript")
                isProcessing = false
                triggerProcessing()
                return
            }

            // --- Diarization (optional) ---
            var finalTranscript = output.transcript
            if diarizeEnabled, let diarizationFactory {
                let diarizer = diarizationFactory()
                if diarizer.isAvailable {
                    updateJobState(id: job.id, to: .diarizing)
                    startElapsedTimer()
                    finalTranscript = try await diarize(
                        job: job, transcript: output, engine: transcriptionEngine,
                        diarizer: diarizer, workDir: workDir,
                    )
                    stopElapsedTimer()
                } else {
                    logger.info("Diarization not available")
                }
            }

            // --- Protocol Generation ---
            updateJobState(id: job.id, to: .generatingProtocol)
            startElapsedTimer()
            let mdPath = try await generateAndSaveProtocol(
                job: job, finalTranscript: finalTranscript,
                generator: protocolGeneratorFactory(), outputDir: outputDir,
            )
            stopElapsedTimer()

            // Update job with protocol path and mark done
            if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[idx].protocolPath = mdPath
            }
            updateJobState(id: job.id, to: .done)
            if let completed = jobs.first(where: { $0.id == job.id }), !completed.warnings.isEmpty {
                NotificationManager.shared.notify(
                    title: "Protocol Ready (with warnings)",
                    body: completed.warnings.joined(separator: "; "),
                )
            }
        } catch is CancellationError {
            stopElapsedTimer()
            logger.info("Job \(job.id) cancelled")
            // Job already removed by cancelJob()
        } catch {
            stopElapsedTimer()
            if cancelledJobIDs.remove(job.id) != nil {
                logger.info("Job \(job.id) cancelled")
            } else {
                logger.error("Pipeline error for job \(job.id): \(error)")
                updateJobState(id: job.id, to: .error, error: error.localizedDescription)
            }
        }

        isProcessing = false
        triggerProcessing()
    }

    // MARK: - Pipeline Stages

    /// Resample and transcribe audio, handling both dual-source and single-source paths.
    private func transcribe(
        job: PipelineJob,
        engine: FluidTranscriptionEngine,
        workDir: URL,
    ) async throws -> TranscriptionOutput {
        // Configure custom vocabulary boosting before transcription
        if !customVocabulary.isEmpty {
            try await engine.configureVocabulary(customVocabulary)
        }

        if let appAudioPath = job.appPath, let micAudioPath = job.micPath {
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
            let segments = engine.mergeDualSourceSegments(
                appSegments: appSegments,
                micSegments: micSegments,
                micDelay: job.micDelay,
                micLabel: micLabel,
            )
            return TranscriptionOutput(
                transcript: segments.map(\.formattedLine).joined(separator: "\n"),
                segments: segments,
                isDualSource: true,
            )
        } else {
            // Single-source: resample mix to 16kHz
            let mix16k = workDir.appendingPathComponent("mix_16k.wav")
            try await AudioMixer.resampleFile(from: job.mixPath, to: mix16k)

            let segments = try await engine.transcribeSegments(audioPath: mix16k)
            return TranscriptionOutput(
                transcript: segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n"),
                segments: segments,
                isDualSource: false,
            )
        }
    }

    /// Run diarization with speaker naming loop. Returns the diarized transcript,
    /// or the original transcript if diarization fails.
    /// Re-throws `CancellationError` so job cancellation propagates.
    private func diarize( // swiftlint:disable:this function_body_length cyclomatic_complexity
        job: PipelineJob,
        transcript: TranscriptionOutput,
        engine: FluidTranscriptionEngine,
        diarizer: DiarizationProvider,
        workDir: URL,
    ) async throws -> String {
        // Ensure mix audio exists for diarization (already resampled in single-source path)
        let mix16k = workDir.appendingPathComponent("mix_16k.wav")
        if !FileManager.default.fileExists(atPath: mix16k.path) {
            try await AudioMixer.resampleFile(from: job.mixPath, to: mix16k)
        }

        do {
            // Diarization + naming loop: re-runs if user requests different speaker count
            var speakerCount = numSpeakers > 0 ? numSpeakers : nil
            var autoNames: [String: String] = [:]

            // Dual-track: separate diarization results
            var appDiarization: DiarizationResult?
            var micDiarization: DiarizationResult?
            // Single-source: combined diarization
            var diarization: DiarizationResult?

            diarizationLoop: while true {
                if transcript.isDualSource {
                    // Diarize app and mic tracks separately
                    let app16k = workDir.appendingPathComponent("app_16k.wav")
                    let mic16k = workDir.appendingPathComponent("mic_16k.wav")

                    appDiarization = try await diarizer.run(
                        audioPath: app16k,
                        numSpeakers: speakerCount,
                        meetingTitle: job.meetingTitle,
                    )
                    micDiarization = try await diarizer.run(
                        audioPath: mic16k,
                        numSpeakers: nil, // auto-detect local speakers
                        meetingTitle: job.meetingTitle,
                    )

                    // Merge for speaker naming (prefixed IDs: R_, M_)
                    // swiftlint:disable force_unwrapping
                    diarization = DiarizationProcess.mergeDualTrackDiarization(
                        appDiarization: appDiarization!,
                        micDiarization: micDiarization!,
                        // swiftlint:enable force_unwrapping
                    )
                } else {
                    diarization = try await diarizer.run(
                        audioPath: mix16k,
                        numSpeakers: speakerCount,
                        meetingTitle: job.meetingTitle,
                    )
                }

                guard let currentDiarization = diarization else { break }
                autoNames = currentDiarization.autoNames

                guard let embeddings = currentDiarization.embeddings else { break }

                let matcher = speakerMatcherFactory()
                let matched = matcher.match(embeddings: embeddings)
                autoNames = matched

                // In dual-track mode, assign micLabel to mic speakers (M_ prefix)
                if transcript.isDualSource, !micLabel.isEmpty {
                    for key in autoNames.keys where key.hasPrefix("M_") {
                        autoNames[key] = micLabel
                    }
                }

                // Pre-match participants to remaining speakers
                if !job.participants.isEmpty {
                    autoNames = SpeakerMatcher.preMatchParticipants(
                        mapping: autoNames,
                        speakingTimes: currentDiarization.speakingTimes,
                        participants: job.participants,
                    )
                }

                let namingData = SpeakerNamingData(
                    jobID: job.id,
                    meetingTitle: job.meetingTitle,
                    mapping: autoNames,
                    speakingTimes: currentDiarization.speakingTimes,
                    embeddings: embeddings,
                    audioPath: mix16k,
                    segments: currentDiarization.segments,
                    participants: job.participants,
                )

                stopElapsedTimer()
                let namingResult: SpeakerNamingResult
                if let handler = speakerNamingHandler {
                    namingResult = await handler(namingData)
                } else {
                    // Start a timeout task that auto-skips if user doesn't respond
                    let timeoutTask = Task { [weak self] in
                        try await Task.sleep(for: .seconds(Self.speakerNamingTimeout))
                        self?.completeSpeakerNaming(result: .skipped)
                    }
                    namingResult = await withCheckedContinuation { continuation in
                        self.speakerNamingContinuation = continuation
                        self.pendingSpeakerNaming = namingData
                        NotificationCenter.default.post(
                            name: .showSpeakerNaming,
                            object: nil,
                        )
                    }
                    timeoutTask.cancel()
                }

                switch namingResult {
                case let .confirmed(userMapping):
                    for (label, name) in userMapping where !name.isEmpty {
                        autoNames[label] = name
                    }
                    matcher.updateDB(mapping: autoNames, embeddings: embeddings)
                    break diarizationLoop

                case let .rerun(count):
                    speakerCount = count
                    updateJobState(id: job.id, to: .diarizing)
                    startElapsedTimer()
                    logger.info("Re-running diarization with \(count) speakers")
                    continue diarizationLoop

                case .skipped:
                    // Use display names as fallback for unmatched speakers
                    let allLabels = Array(autoNames.keys)
                    for (label, name) in autoNames where name == label {
                        autoNames[label] = speakerDisplayName(label, allLabels: allLabels)
                    }
                    addWarning(id: job.id, "Speaker naming skipped")
                    break diarizationLoop
                }
            }

            // Apply speaker names to segments
            let finalTranscript: String
            if transcript.isDualSource, let appDiar = appDiarization, let micDiar = micDiarization,
               let cached = transcript.segments {
                // Dual-track: assign from respective diarizations
                let namedAppDiar = DiarizationResult(
                    segments: appDiar.segments,
                    speakingTimes: appDiar.speakingTimes,
                    autoNames: autoNames.filter { $0.key.hasPrefix("R_") }
                        .reduce(into: [:]) { $0[String($1.key.dropFirst(2))] = $1.value },
                    embeddings: appDiar.embeddings,
                )
                let namedMicDiar = DiarizationResult(
                    segments: micDiar.segments,
                    speakingTimes: micDiar.speakingTimes,
                    autoNames: autoNames.filter { $0.key.hasPrefix("M_") }
                        .reduce(into: [:]) { $0[String($1.key.dropFirst(2))] = $1.value },
                    embeddings: micDiar.embeddings,
                )

                let appSegs = cached.filter { $0.speaker == "Remote" }
                let micSegs = cached.filter { $0.speaker == micLabel }
                let labeled = DiarizationProcess.assignSpeakersDualTrack(
                    appSegments: appSegs,
                    micSegments: micSegs,
                    appDiarization: namedAppDiar,
                    micDiarization: namedMicDiar,
                )
                let merged = DiarizationProcess.mergeConsecutiveSpeakers(labeled)
                finalTranscript = merged.map(\.formattedLine).joined(separator: "\n")
            } else if let currentDiarization = diarization {
                // Single-source: standard assignment
                let namedDiarization = DiarizationResult(
                    segments: currentDiarization.segments,
                    speakingTimes: currentDiarization.speakingTimes,
                    autoNames: autoNames,
                    embeddings: currentDiarization.embeddings,
                )
                let segments: [TimestampedSegment] = if let cached = transcript.segments {
                    cached
                } else {
                    try await engine.transcribeSegments(audioPath: mix16k)
                }
                let labeled = DiarizationProcess.assignSpeakers(
                    transcript: segments,
                    diarization: namedDiarization,
                )
                let merged = DiarizationProcess.mergeConsecutiveSpeakers(labeled)
                finalTranscript = merged.map(\.formattedLine).joined(separator: "\n")
            } else {
                finalTranscript = transcript.transcript
            }

            let segCount = diarization?.segments.count ?? 0
            logger.info("Diarization complete: \(segCount) segments")
            return finalTranscript
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Diarization failed, using undiarized transcript: \(error.localizedDescription)")
            addWarning(id: job.id, "Diarization failed — speakers not identified")
            return transcript.transcript
        }
    }

    /// Save transcript, generate protocol, save protocol, and copy audio files.
    /// Returns the path to the saved protocol markdown file.
    private func generateAndSaveProtocol(
        job: PipelineJob,
        finalTranscript: String,
        generator: ProtocolGenerating,
        outputDir: URL,
    ) async throws -> URL {
        let protocolsDir = outputDir.appendingPathComponent("protocols")
        let txtPath = try ProtocolGenerator.saveTranscript(
            finalTranscript, title: job.meetingTitle, dir: protocolsDir,
        )
        logger.info("Transcript saved: \(txtPath.lastPathComponent)")

        let diarized = finalTranscript.range(of: #"\[\w[\w\s]*\]"#, options: .regularExpression) != nil
        let protocolMD = try await generator.generate(
            transcript: finalTranscript,
            title: job.meetingTitle,
            diarized: diarized,
        )

        let fullMD = protocolMD + "\n\n---\n\n## Full Transcript\n\n" + finalTranscript
        let mdPath = try ProtocolGenerator.saveProtocol(
            fullMD, title: job.meetingTitle, dir: protocolsDir,
        )
        logger.info("Protocol saved: \(mdPath.lastPathComponent)")

        // Move audio files to recordings subdirectory
        let recordingsDir = outputDir.appendingPathComponent("recordings")
        Self.copyAudioToOutput(
            mixPath: job.mixPath, appPath: job.appPath, micPath: job.micPath,
            title: job.meetingTitle, outputDir: recordingsDir,
        )

        return mdPath
    }

    // MARK: - Snapshot Recovery

    /// Load pipeline queue from the JSON snapshot written by `writeSnapshot()`.
    /// Resets in-progress jobs to `.waiting`, discards `.done` jobs, and drops
    /// jobs whose `mixPath` no longer exists on disk.
    func loadSnapshot() {
        let snapshotPath = logDir.appendingPathComponent("pipeline_queue.json")
        guard FileManager.default.fileExists(atPath: snapshotPath.path) else {
            logger.info("No pipeline snapshot to restore")
            return
        }
        do {
            let data = try Data(contentsOf: snapshotPath)
            var loaded = try JSONDecoder().decode([PipelineJob].self, from: data)

            // Reset active states back to waiting
            for i in loaded.indices {
                switch loaded[i].state {
                case .transcribing, .diarizing, .generatingProtocol:
                    loaded[i].state = .waiting

                default:
                    break
                }
            }

            // Discard done jobs
            loaded.removeAll { $0.state == .done }

            // Discard jobs whose audio file no longer exists
            loaded.removeAll { !FileManager.default.fileExists(atPath: $0.mixPath.path) }

            guard !loaded.isEmpty else {
                logger.info("Snapshot loaded but no recoverable jobs")
                return
            }

            jobs = loaded
            writeSnapshot()
            logger.info("Restored \(loaded.count) jobs from snapshot")
            triggerProcessing()
        } catch {
            logger.error("Failed to load pipeline snapshot: \(error)")
        }
    }

    // MARK: - Audio File Copy

    /// Copy recording audio files to the protocol output directory.
    private static func copyAudioToOutput(
        mixPath: URL, appPath: URL?, micPath: URL?,
        title: String, outputDir: URL,
    ) {
        let accessing = outputDir.startAccessingSecurityScopedResource()
        defer { if accessing { outputDir.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let slug = ProtocolGenerator.filename(title: title, ext: "").dropLast() // remove trailing "."
        let audioPaths: [(URL, String)] = [
            (mixPath, "\(slug)_mix.\(mixPath.pathExtension)"),
            appPath.map { ($0, "\(slug)_app.\($0.pathExtension)") },
            micPath.map { ($0, "\(slug)_mic.\($0.pathExtension)") },
        ].compactMap(\.self)

        for (src, name) in audioPaths {
            let dst = outputDir.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.moveItem(at: src, to: dst)
                logger.info("Audio moved: \(name)")
            } catch {
                logger.warning("Failed to move audio \(name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Orphaned Recording Recovery

    /// One-time migration: if no processed_recordings.json exists yet, seed it with
    /// all existing `_mix.wav` files so they don't get recovered on first launch after update.
    private func migrateProcessedRecordings(recordingsDir: URL) {
        guard !FileManager.default.fileExists(atPath: processedRecordingsPath.path) else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: nil,
        ) else { return }

        var paths = Set<String>()
        for file in entries where file.lastPathComponent.hasSuffix("_mix.wav")
            || file.lastPathComponent.hasSuffix("_mix.m4a") {
            paths.insert(file.standardizedFileURL.path)
        }
        guard !paths.isEmpty else { return }
        do {
            ensureLogDir()
            let data = try JSONEncoder().encode(Array(paths))
            try data.write(to: processedRecordingsPath, options: .atomic)
            logger.info("Migration: seeded \(paths.count) existing recordings as processed")
        } catch {
            logger.error("Migration failed: \(error)")
        }
    }

    /// Scan `recordingsDir` for `*_mix.m4a` / `*_mix.wav` files not tracked by any loaded job.
    /// Creates recovery jobs for untracked recordings younger than `maxAge`.
    /// Skips files that were already successfully processed (tracked in processed_recordings.json).
    func recoverOrphanedRecordings(
        recordingsDir: URL = AppPaths.recordingsDir,
        maxAge: TimeInterval = 86400,
    ) {
        // One-time migration: seed processed list with existing recordings
        // Only for the default recordings directory (not test overrides)
        if recordingsDir == AppPaths.recordingsDir {
            migrateProcessedRecordings(recordingsDir: recordingsDir)
        }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
        ) else { return }

        let trackedPaths = Set(jobs.map(\.mixPath.standardizedFileURL.path))
        let processedPaths = loadProcessedPaths()
        let now = Date()
        var recovered = 0

        for file in entries where file.lastPathComponent.hasSuffix("_mix.m4a")
            || file.lastPathComponent.hasSuffix("_mix.wav") {
            let stdPath = file.standardizedFileURL.path

            // Skip already tracked by active jobs
            guard !trackedPaths.contains(stdPath) else { continue }

            // Skip already successfully processed
            guard !processedPaths.contains(stdPath) else { continue }

            // Skip files older than maxAge
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let created = attrs[.creationDate] as? Date,
               now.timeIntervalSince(created) > maxAge {
                continue
            }

            // Skip empty audio files (WAV header = 44 bytes, M4A headers vary)
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int, size <= 100 {
                continue
            }

            // Derive timestamp prefix (e.g. "20260311_143000" from "20260311_143000_mix.m4a")
            let name = file.deletingPathExtension().lastPathComponent
            let prefix = String(name.dropLast("_mix".count))
            let ext = file.pathExtension

            // Look for companion tracks (match extension of mix file)
            let appFile = recordingsDir.appendingPathComponent("\(prefix)_app.\(ext)")
            let micFile = recordingsDir.appendingPathComponent("\(prefix)_mic.\(ext)")
            let appPath = fm.fileExists(atPath: appFile.path) ? appFile : nil
            let micPath = fm.fileExists(atPath: micFile.path) ? micFile : nil

            let job = PipelineJob(
                meetingTitle: "Recovered Recording (\(prefix))",
                appName: "Unknown",
                mixPath: file,
                appPath: appPath,
                micPath: micPath,
                micDelay: 0,
            )
            jobs.append(job)
            appendLog(jobID: job.id, event: "recovered", from: nil, to: .waiting)
            recovered += 1
        }

        if recovered > 0 {
            writeSnapshot()
            logger.info("Recovered \(recovered) orphaned recording(s)")
            triggerProcessing()
        }
    }

    // MARK: - Processed Recordings Tracking

    private var processedRecordingsPath: URL {
        logDir.appendingPathComponent("processed_recordings.json")
    }

    /// Load the set of mix paths that completed successfully.
    private func loadProcessedPaths() -> Set<String> {
        guard let data = try? Data(contentsOf: processedRecordingsPath),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths)
    }

    /// Record that a job's mix file was successfully processed.
    func markProcessed(mixPath: URL) {
        var paths = loadProcessedPaths()
        paths.insert(mixPath.standardizedFileURL.path)
        do {
            ensureLogDir()
            let data = try JSONEncoder().encode(Array(paths))
            try data.write(to: processedRecordingsPath, options: .atomic)
        } catch {
            logger.error("Failed to write processed recordings: \(error)")
        }
    }

    // MARK: - JSON Logging

    private static let isoFormatter = ISO8601DateFormatter()
    private var logDirCreated = false

    private func ensureLogDir() {
        guard !logDirCreated else { return }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        logDirCreated = true
    }

    private func writeSnapshot() {
        do {
            ensureLogDir()
            let data = try JSONEncoder().encode(jobs)
            let tmpPath = logDir.appendingPathComponent("pipeline_queue.tmp")
            try data.write(to: tmpPath)
            let snapshotPath = logDir.appendingPathComponent("pipeline_queue.json")
            _ = try FileManager.default.replaceItemAt(snapshotPath, withItemAt: tmpPath)
        } catch {
            logger.error("Failed to write queue snapshot: \(error)")
        }
    }

    private func appendLog(jobID: UUID, event: String, from: JobState?, to: JobState) {
        let entry: [String: String] = [
            "timestamp": Self.isoFormatter.string(from: Date()),
            "job_id": jobID.uuidString,
            "event": event,
            "from": from?.rawValue ?? "-",
            "to": to.rawValue,
        ]
        do {
            ensureLogDir()
            let data = try JSONEncoder().encode(entry)
            let logPath = logDir.appendingPathComponent("pipeline_log.jsonl")
            // swiftlint:disable:next force_unwrapping
            let line = String(data: data, encoding: .utf8)! + "\n"
            if FileManager.default.fileExists(atPath: logPath.path) {
                let handle = try FileHandle(forWritingTo: logPath)
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                // swiftlint:disable:next force_unwrapping
                handle.write(line.data(using: .utf8)!)
            } else {
                try line.write(to: logPath, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to append pipeline log: \(error)")
        }
    }
}
