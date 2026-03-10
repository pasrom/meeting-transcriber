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
    let protocolGenerator: ProtocolGenerating?
    let outputDir: URL?
    let diarizeEnabled: Bool
    let numSpeakers: Int
    let micLabel: String
    let claudeBin: String
    let speakerMatcherFactory: () -> SpeakerMatcher

    let completedJobLifetime: TimeInterval

    private(set) var isProcessing = false
    private var processTask: Task<Void, Never>?

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
        self.protocolGenerator = nil
        self.outputDir = nil
        self.diarizeEnabled = false
        self.numSpeakers = 0
        self.micLabel = "Me"
        self.claudeBin = "claude"
        self.speakerMatcherFactory = { SpeakerMatcher() }
        self.completedJobLifetime = completedJobLifetime
    }

    /// Full init with all processing dependencies.
    init(
        logDir: URL? = nil,
        whisperKit: WhisperKitEngine,
        diarizationFactory: @escaping () -> DiarizationProvider,
        protocolGenerator: ProtocolGenerating,
        outputDir: URL,
        diarizeEnabled: Bool = false,
        numSpeakers: Int = 0,
        micLabel: String = "Me",
        claudeBin: String = "claude",
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = { SpeakerMatcher() },
        completedJobLifetime: TimeInterval = 60
    ) {
        self.logDir = logDir ?? AppPaths.ipcDir
        self.whisperKit = whisperKit
        self.diarizationFactory = diarizationFactory
        self.protocolGenerator = protocolGenerator
        self.outputDir = outputDir
        self.diarizeEnabled = diarizeEnabled
        self.numSpeakers = numSpeakers
        self.micLabel = micLabel
        self.claudeBin = claudeBin
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
        jobs.removeAll { $0.id == id }
        writeSnapshot()
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
        guard let whisperKit, let protocolGenerator, let outputDir else {
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
                // Dual-source: resample both tracks to 16kHz
                let app16k = workDir.appendingPathComponent("app_16k.wav")
                try AudioMixer.resampleFile(from: appAudioPath, to: app16k)

                let mic16k = workDir.appendingPathComponent("mic_16k.wav")
                try AudioMixer.resampleFile(from: micAudioPath, to: mic16k)

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
                try AudioMixer.resampleFile(from: mixPath, to: mix16k)

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
                        try AudioMixer.resampleFile(from: mixPath, to: mix16k)
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
            let protocolMD = try await protocolGenerator.generate(
                transcript: finalTranscript,
                title: title,
                diarized: diarized,
                claudeBin: claudeBin
            )

            let fullMD = protocolMD + "\n\n---\n\n## Full Transcript\n\n" + finalTranscript
            let mdPath = try ProtocolGenerator.saveProtocol(fullMD, title: title, dir: outputDir)
            logger.info("Protocol saved: \(mdPath.lastPathComponent)")

            // Update job with protocol path and mark done
            if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[idx].protocolPath = mdPath
            }
            updateJobState(id: jobID, to: .done)

        } catch {
            logger.error("Pipeline error for job \(jobID): \(error)")
            updateJobState(id: jobID, to: .error, error: error.localizedDescription)
        }

        isProcessing = false
        triggerProcessing()
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
