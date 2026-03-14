import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

@MainActor
@Observable
class PipelineQueue {
    private(set) var jobs: [PipelineJob] = []
    private let logDir: URL

    // Dependencies for processing
    let whisperKit: WhisperKitEngine?
    let diarizationFactory: (() -> DiarizationProvider)?
    let protocolGeneratorFactory: (() -> ProtocolGenerating)?
    let outputDir: URL?
    let diarizeEnabled: Bool
    let numSpeakers: Int
    let micLabel: String
    let speakerMatcherFactory: () -> SpeakerMatcher

    let completedJobLifetime: TimeInterval

    private(set) var isProcessing = false
    private var processTask: Task<Void, Never>?
    private var cancelledJobIDs = Set<UUID>()

    /// Called when a job completes (success or error) — for notifications
    var onJobStateChange: ((PipelineJob, JobState, JobState) -> Void)?

    // MARK: - Speaker Naming

    /// Data for the speaker naming popup.
    struct SpeakerNamingData {
        let jobID: UUID
        let meetingTitle: String
        let mapping: [String: String]       // label → auto-matched name or label
        let speakingTimes: [String: TimeInterval]
        let embeddings: [String: [Float]]
        let audioPath: URL?                 // 16kHz mix for playback
        let segments: [DiarizationResult.Segment]  // for extracting speaker snippets
        let participants: [String]          // Teams participant names as suggestions
    }

    /// Result from the speaker naming popup.
    enum SpeakerNamingResult {
        case confirmed([String: String])   // user confirmed with mapping
        case rerun(Int)                     // re-run diarization with N speakers
        case skipped                        // user skipped
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
        self.whisperKit = nil
        self.diarizationFactory = nil
        self.protocolGeneratorFactory = nil
        self.outputDir = nil
        self.diarizeEnabled = false
        self.numSpeakers = 0
        self.micLabel = "Me"
        self.speakerMatcherFactory = { SpeakerMatcher() }
        self.completedJobLifetime = completedJobLifetime
    }

    /// Full init with all processing dependencies.
    init(
        logDir: URL? = nil,
        whisperKit: WhisperKitEngine,
        diarizationFactory: @escaping () -> DiarizationProvider,
        protocolGeneratorFactory: @escaping () -> ProtocolGenerating,
        outputDir: URL,
        diarizeEnabled: Bool = false,
        numSpeakers: Int = 0,
        micLabel: String = "Me",
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = { SpeakerMatcher() },
        completedJobLifetime: TimeInterval = 60
    ) {
        self.logDir = logDir ?? AppPaths.ipcDir
        self.whisperKit = whisperKit
        self.diarizationFactory = diarizationFactory
        self.protocolGeneratorFactory = protocolGeneratorFactory
        self.outputDir = outputDir
        self.diarizeEnabled = diarizeEnabled
        self.numSpeakers = numSpeakers
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

    var errorJobs: [PipelineJob] {
        jobs.filter { $0.state == .error }
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

        if newState == .done {
            markProcessed(mixPath: jobs[index].mixPath)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.completedJobLifetime ?? 60))
                self?.removeJob(id: id)
            }
        }
    }

    // MARK: - Processing

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
        guard let whisperKit, let protocolGeneratorFactory, let outputDir else {
            logger.warning("Processing dependencies not configured — skipping")
            isProcessing = false
            return
        }
        let jobID = jobs[index].id
        let title = jobs[index].meetingTitle
        let mixPath = jobs[index].mixPath
        let appPath = jobs[index].appPath
        let micPath = jobs[index].micPath
        let micDelay = jobs[index].micDelay
        let participants = jobs[index].participants

        do {
            // --- Transcription ---
            updateJobState(id: jobID, to: .transcribing)

            // Create a temp directory for intermediate 16kHz files
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pipeline_\(jobID.uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            let transcript: String
            // Segments cached for potential diarization reuse (avoids double transcription)
            var cachedSegments: [TimestampedSegment]?
            let isDualSource = appPath != nil && micPath != nil
            if let appAudioPath = appPath, let micAudioPath = micPath {
                // Dual-source: resample both tracks to 16kHz concurrently
                let app16k = workDir.appendingPathComponent("app_16k.wav")
                let mic16k = workDir.appendingPathComponent("mic_16k.wav")
                async let appResample: Void = AudioMixer.resampleFile(from: appAudioPath, to: app16k)
                async let micResample: Void = AudioMixer.resampleFile(from: micAudioPath, to: mic16k)
                try await appResample
                try await micResample

                // Use segment-returning method to cache for hybrid diarization
                let segments = try await whisperKit.transcribeDualSourceSegments(
                    appAudio: app16k,
                    micAudio: mic16k,
                    micDelay: micDelay,
                    micLabel: micLabel
                )
                cachedSegments = segments
                transcript = segments.map(\.formattedLine).joined(separator: "\n")
            } else {
                // Single-source: resample mix to 16kHz
                let mix16k = workDir.appendingPathComponent("mix_16k.wav")
                try await AudioMixer.resampleFile(from: mixPath, to: mix16k)

                // Use transcribeSegments to cache results for diarization
                let segments = try await whisperKit.transcribeSegments(audioPath: mix16k)
                cachedSegments = segments
                transcript = segments.map { "\($0.formattedTimestamp) \($0.text)" }.joined(separator: "\n")
            }

            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                updateJobState(id: jobID, to: .error, error: "Empty transcript")
                isProcessing = false
                triggerProcessing()
                return
            }

            // --- Diarization (optional) ---
            var finalTranscript = transcript
            if diarizeEnabled, let diarizationFactory {
                let diarizeProcess = diarizationFactory()
                if diarizeProcess.isAvailable {
                    updateJobState(id: jobID, to: .diarizing)

                    // Use mix audio for diarization (already resampled in single-source path)
                    let mix16k = workDir.appendingPathComponent("mix_16k.wav")
                    if !FileManager.default.fileExists(atPath: mix16k.path) {
                        try await AudioMixer.resampleFile(from: mixPath, to: mix16k)
                    }

                    do {
                        let useDualTrack = isDualSource

                        // Diarization + naming loop: re-runs if user requests different speaker count
                        var speakerCount = numSpeakers > 0 ? numSpeakers : nil
                        var autoNames: [String: String] = [:]

                        // Dual-track: separate diarization results
                        var appDiarization: DiarizationResult?
                        var micDiarization: DiarizationResult?
                        // Single-source: combined diarization
                        var diarization: DiarizationResult?

                        diarizationLoop: while true {
                            if useDualTrack {
                                // Diarize app and mic tracks separately
                                let app16k = workDir.appendingPathComponent("app_16k.wav")
                                let mic16k_ = workDir.appendingPathComponent("mic_16k.wav")

                                appDiarization = try await diarizeProcess.run(
                                    audioPath: app16k,
                                    numSpeakers: speakerCount,
                                    meetingTitle: title
                                )
                                micDiarization = try await diarizeProcess.run(
                                    audioPath: mic16k_,
                                    numSpeakers: nil,  // auto-detect local speakers
                                    meetingTitle: title
                                )

                                // Merge for speaker naming (prefixed IDs: R_, M_)
                                diarization = DiarizationProcess.mergeDualTrackDiarization(
                                    appDiarization: appDiarization!,
                                    micDiarization: micDiarization!
                                )
                            } else {
                                diarization = try await diarizeProcess.run(
                                    audioPath: mix16k,
                                    numSpeakers: speakerCount,
                                    meetingTitle: title
                                )
                            }

                            guard let currentDiarization = diarization else { break }
                            autoNames = currentDiarization.autoNames

                            guard let embeddings = currentDiarization.embeddings else { break }

                            let matcher = speakerMatcherFactory()
                            let matched = matcher.match(embeddings: embeddings)
                            autoNames = matched

                            // Pre-match participants to remaining speakers
                            if !participants.isEmpty {
                                autoNames = SpeakerMatcher.preMatchParticipants(
                                    mapping: autoNames,
                                    speakingTimes: currentDiarization.speakingTimes,
                                    participants: participants
                                )
                            }

                            let namingData = SpeakerNamingData(
                                jobID: jobID,
                                meetingTitle: title,
                                mapping: autoNames,
                                speakingTimes: currentDiarization.speakingTimes,
                                embeddings: embeddings,
                                audioPath: mix16k,
                                segments: currentDiarization.segments,
                                participants: participants
                            )

                            let namingResult: SpeakerNamingResult
                            if let handler = speakerNamingHandler {
                                namingResult = await handler(namingData)
                            } else {
                                // Start a timeout task that auto-skips if user doesn't respond
                                let timeoutTask = Task { [weak self] in
                                    try await Task.sleep(for: .seconds(Self.speakerNamingTimeout))
                                    await self?.completeSpeakerNaming(result: .skipped)
                                }
                                namingResult = await withCheckedContinuation { continuation in
                                    self.speakerNamingContinuation = continuation
                                    self.pendingSpeakerNaming = namingData
                                    NotificationCenter.default.post(
                                        name: .showSpeakerNaming,
                                        object: nil
                                    )
                                }
                                timeoutTask.cancel()
                            }

                            switch namingResult {
                            case .confirmed(let userMapping):
                                for (label, name) in userMapping where !name.isEmpty {
                                    autoNames[label] = name
                                }
                                matcher.updateDB(mapping: autoNames, embeddings: embeddings)
                                break diarizationLoop

                            case .rerun(let count):
                                speakerCount = count
                                updateJobState(id: jobID, to: .diarizing)
                                logger.info("Re-running diarization with \(count) speakers")
                                continue diarizationLoop

                            case .skipped:
                                break diarizationLoop
                            }
                        }

                        // Apply speaker names to segments
                        if useDualTrack, let appDiar = appDiarization, let micDiar = micDiarization,
                           let cached = cachedSegments {
                            // Dual-track: assign from respective diarizations
                            let namedAppDiar = DiarizationResult(
                                segments: appDiar.segments,
                                speakingTimes: appDiar.speakingTimes,
                                autoNames: autoNames.filter { $0.key.hasPrefix("R_") }
                                    .reduce(into: [:]) { $0[String($1.key.dropFirst(2))] = $1.value },
                                embeddings: appDiar.embeddings
                            )
                            let namedMicDiar = DiarizationResult(
                                segments: micDiar.segments,
                                speakingTimes: micDiar.speakingTimes,
                                autoNames: autoNames.filter { $0.key.hasPrefix("M_") }
                                    .reduce(into: [:]) { $0[String($1.key.dropFirst(2))] = $1.value },
                                embeddings: micDiar.embeddings
                            )

                            let appSegs = cached.filter { $0.speaker == "Remote" }
                            let micSegs = cached.filter { $0.speaker == micLabel }
                            let labeled = DiarizationProcess.assignSpeakersDualTrack(
                                appSegments: appSegs,
                                micSegments: micSegs,
                                appDiarization: namedAppDiar,
                                micDiarization: namedMicDiar
                            )
                            finalTranscript = labeled.map(\.formattedLine).joined(separator: "\n")
                        } else if let currentDiarization = diarization {
                            // Single-source: standard assignment
                            let namedDiarization = DiarizationResult(
                                segments: currentDiarization.segments,
                                speakingTimes: currentDiarization.speakingTimes,
                                autoNames: autoNames,
                                embeddings: currentDiarization.embeddings
                            )
                            let segments: [TimestampedSegment]
                            if let cached = cachedSegments {
                                segments = cached
                            } else {
                                segments = try await whisperKit.transcribeSegments(
                                    audioPath: mix16k
                                )
                            }
                            let labeled = DiarizationProcess.assignSpeakers(
                                transcript: segments,
                                diarization: namedDiarization
                            )
                            finalTranscript = labeled.map(\.formattedLine).joined(separator: "\n")
                        }
                        let segCount = diarization?.segments.count ?? 0
                        logger.info("Diarization complete: \(segCount) segments")
                    } catch {
                        logger.warning("Diarization failed, using undiarized transcript: \(error.localizedDescription)")
                        // Continue with original transcript
                    }
                } else {
                    logger.info("Diarization not available")
                }
            }

            // Save transcript
            let txtPath = try ProtocolGenerator.saveTranscript(finalTranscript, title: title, dir: outputDir)
            logger.info("Transcript saved: \(txtPath.lastPathComponent)")

            // --- Protocol Generation ---
            updateJobState(id: jobID, to: .generatingProtocol)

            let diarized = finalTranscript.range(of: #"\[\w[\w\s]*\]"#, options: .regularExpression) != nil
            let protocolGenerator = protocolGeneratorFactory()
            let protocolMD = try await protocolGenerator.generate(
                transcript: finalTranscript,
                title: title,
                diarized: diarized
            )

            let fullMD = protocolMD + "\n\n---\n\n## Full Transcript\n\n" + finalTranscript
            let mdPath = try ProtocolGenerator.saveProtocol(fullMD, title: title, dir: outputDir)
            logger.info("Protocol saved: \(mdPath.lastPathComponent)")

            // Update job with protocol path and mark done
            if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[idx].protocolPath = mdPath
            }
            updateJobState(id: jobID, to: .done)

        } catch is CancellationError {
            logger.info("Job \(jobID) cancelled")
            // Job already removed by cancelJob()
        } catch {
            if cancelledJobIDs.remove(jobID) != nil {
                logger.info("Job \(jobID) cancelled")
            } else {
                logger.error("Pipeline error for job \(jobID): \(error)")
                updateJobState(id: jobID, to: .error, error: error.localizedDescription)
            }
        }

        isProcessing = false
        triggerProcessing()
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

    // MARK: - Orphaned Recording Recovery

    /// One-time migration: if no processed_recordings.json exists yet, seed it with
    /// all existing `_mix.wav` files so they don't get recovered on first launch after update.
    private func migrateProcessedRecordings(recordingsDir: URL) {
        guard !FileManager.default.fileExists(atPath: processedRecordingsPath.path) else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: nil
        ) else { return }

        var paths = Set<String>()
        for file in entries where file.lastPathComponent.hasSuffix("_mix.wav") {
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

    /// Scan `recordingsDir` for `*_mix.wav` files not tracked by any loaded job.
    /// Creates recovery jobs for untracked recordings younger than `maxAge`.
    /// Skips files that were already successfully processed (tracked in processed_recordings.json).
    func recoverOrphanedRecordings(
        recordingsDir: URL = AppPaths.recordingsDir,
        maxAge: TimeInterval = 86400
    ) {
        // One-time migration: seed processed list with existing recordings
        // Only for the default recordings directory (not test overrides)
        if recordingsDir == AppPaths.recordingsDir {
            migrateProcessedRecordings(recordingsDir: recordingsDir)
        }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else { return }

        let trackedPaths = Set(jobs.map { $0.mixPath.standardizedFileURL.path })
        let processedPaths = loadProcessedPaths()
        let now = Date()
        var recovered = 0

        for file in entries where file.lastPathComponent.hasSuffix("_mix.wav") {
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

            // Skip empty WAVs (header only = 44 bytes)
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int, size <= 44 {
                continue
            }

            // Derive timestamp prefix (e.g. "20260311_143000" from "20260311_143000_mix.wav")
            let name = file.deletingPathExtension().lastPathComponent
            let prefix = String(name.dropLast("_mix".count))

            // Look for companion tracks
            let appFile = recordingsDir.appendingPathComponent("\(prefix)_app.wav")
            let micFile = recordingsDir.appendingPathComponent("\(prefix)_mic.wav")
            let appPath = fm.fileExists(atPath: appFile.path) ? appFile : nil
            let micPath = fm.fileExists(atPath: micFile.path) ? micFile : nil

            let job = PipelineJob(
                meetingTitle: "Recovered Recording (\(prefix))",
                appName: "Unknown",
                mixPath: file,
                appPath: appPath,
                micPath: micPath,
                micDelay: 0
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
            let line = String(data: data, encoding: .utf8)! + "\n"
            if FileManager.default.fileExists(atPath: logPath.path) {
                let handle = try FileHandle(forWritingTo: logPath)
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try line.write(to: logPath, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to append pipeline log: \(error)")
        }
    }
}
