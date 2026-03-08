import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber", category: "PipelineQueue")

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
    let micLabel: String
    let claudeBin: String

    private(set) var isProcessing = false
    private var processTask: Task<Void, Never>?

    /// Called when a job completes (success or error) — for notifications
    var onJobStateChange: ((PipelineJob, JobState, JobState) -> Void)?

    /// Simple init for skeleton tests and basic queue usage.
    init(logDir: URL? = nil) {
        self.logDir = logDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        self.whisperKit = nil
        self.diarizationFactory = nil
        self.protocolGenerator = nil
        self.outputDir = nil
        self.diarizeEnabled = false
        self.micLabel = "Me"
        self.claudeBin = "claude"
    }

    /// Full init with all processing dependencies.
    init(
        logDir: URL? = nil,
        whisperKit: WhisperKitEngine,
        diarizationFactory: @escaping () -> DiarizationProvider,
        protocolGenerator: ProtocolGenerating,
        outputDir: URL,
        diarizeEnabled: Bool = false,
        micLabel: String = "Me",
        claudeBin: String = "claude"
    ) {
        self.logDir = logDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        self.whisperKit = whisperKit
        self.diarizationFactory = diarizationFactory
        self.protocolGenerator = protocolGenerator
        self.outputDir = outputDir
        self.diarizeEnabled = diarizeEnabled
        self.micLabel = micLabel
        self.claudeBin = claudeBin
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
    }

    // MARK: - Processing

    /// Kick off processing if not already running and there are waiting jobs.
    private func triggerProcessing() {
        guard !isProcessing else { return }
        guard pendingJobs.first != nil else { return }
        processTask = Task { [weak self] in
            await self?.processNext()
        }
    }

    /// Process the first waiting job through the full pipeline:
    /// resample → transcribe → (diarize) → save transcript → generate protocol → save protocol.
    func processNext() async {
        guard let index = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        guard let whisperKit, let protocolGenerator, let outputDir else {
            logger.warning("Processing dependencies not configured — skipping")
            return
        }

        isProcessing = true
        let jobID = jobs[index].id
        let title = jobs[index].meetingTitle
        let mixPath = jobs[index].mixPath
        let appPath = jobs[index].appPath
        let micPath = jobs[index].micPath

        do {
            // --- Transcription ---
            updateJobState(id: jobID, to: .transcribing)

            // Create a temp directory for intermediate 16kHz files
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pipeline_\(jobID.uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            let transcript: String
            if let appAudioPath = appPath, let micAudioPath = micPath {
                // Dual-source: resample both tracks to 16kHz
                let app16k = workDir.appendingPathComponent("app_16k.wav")
                let appSamples = try AudioMixer.loadWAVAsFloat32(url: appAudioPath)
                try AudioMixer.saveWAV(
                    samples: AudioMixer.resample(appSamples, from: 48000, to: 16000),
                    sampleRate: 16000, url: app16k
                )

                let mic16k = workDir.appendingPathComponent("mic_16k.wav")
                let micSamples = try AudioMixer.loadWAVAsFloat32(url: micAudioPath)
                try AudioMixer.saveWAV(
                    samples: AudioMixer.resample(micSamples, from: 48000, to: 16000),
                    sampleRate: 16000, url: mic16k
                )

                transcript = try await whisperKit.transcribeDualSource(
                    appAudio: app16k,
                    micAudio: mic16k,
                    micDelay: jobs[index].micDelay,
                    micLabel: micLabel
                )
            } else {
                // Single-source: resample mix to 16kHz
                let mix16k = workDir.appendingPathComponent("mix_16k.wav")
                let mixSamples = try AudioMixer.loadWAVAsFloat32(url: mixPath)
                try AudioMixer.saveWAV(
                    samples: AudioMixer.resample(mixSamples, from: 48000, to: 16000),
                    sampleRate: 16000, url: mix16k
                )
                transcript = try await whisperKit.transcribe(audioPath: mix16k)
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

                    // Use mix audio for diarization
                    let mix16k = workDir.appendingPathComponent("mix_16k.wav")
                    if !FileManager.default.fileExists(atPath: mix16k.path) {
                        let mixSamples = try AudioMixer.loadWAVAsFloat32(url: mixPath)
                        try AudioMixer.saveWAV(
                            samples: AudioMixer.resample(mixSamples, from: 48000, to: 16000),
                            sampleRate: 16000, url: mix16k
                        )
                    }

                    do {
                        let diarization = try await diarizeProcess.run(
                            audioPath: mix16k,
                            numSpeakers: nil,
                            meetingTitle: title
                        )

                        // Re-transcribe segments and assign speakers
                        let segmentAudioPath: URL
                        if appPath != nil {
                            segmentAudioPath = workDir.appendingPathComponent("app_16k.wav")
                        } else {
                            segmentAudioPath = mix16k
                        }

                        let appSegments = try await whisperKit.transcribeSegments(
                            audioPath: segmentAudioPath
                        )

                        let labeled = DiarizationProcess.assignSpeakers(
                            transcript: appSegments,
                            diarization: diarization
                        )
                        finalTranscript = labeled.map(\.formattedLine).joined(separator: "\n")
                        logger.info("Diarization complete: \(diarization.segments.count) segments")
                    } catch {
                        logger.warning("Diarization failed, using undiarized transcript: \(error.localizedDescription)")
                        // Continue with original transcript
                    }
                } else {
                    logger.info("Diarization not available (python-diarize not in bundle)")
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

            let fullMD = protocolMD + "\n\n---\n\n## Full Transcript\n\n" + transcript
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

    private func writeSnapshot() {
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
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
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "job_id": jobID.uuidString,
            "event": event,
            "from": from?.rawValue ?? "-",
            "to": to.rawValue,
        ]
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
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
