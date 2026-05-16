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
    let engine: (any TranscribingEngine)?
    let diarizationFactory: (() -> any DiarizationProvider)?
    let protocolGeneratorFactory: (() -> (any ProtocolGenerating)?)?
    let outputDir: URL?
    let diarizeEnabled: Bool
    let numSpeakers: Int
    let micLabel: String
    let speakerMatcherFactory: () -> SpeakerMatcher
    let vadConfig: VADConfig?
    /// nil disables JSONL logging. AppState injects a real instance for production;
    /// tests leave it nil unless they explicitly want to assert on the log.
    let recognitionStatsLog: RecognitionStatsLog?

    let completedJobLifetime: TimeInterval

    /// Cached FluidVAD instance — reused across jobs to avoid model reload.
    private var vad: FluidVAD?

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
    struct SpeakerNamingData: Codable {
        let jobID: UUID
        let meetingTitle: String
        let mapping: [String: String] // label → auto-matched name or label
        let speakingTimes: [String: TimeInterval]
        let embeddings: [String: [Float]]
        let audioPath: URL? // 16kHz mix for playback
        let segments: [Segment] // for extracting speaker snippets
        let participants: [String] // Teams participant names as suggestions
        let isDualSource: Bool
        /// Per-instance identity for SwiftUI `.onChange` change-detection.
        /// Late re-diarization can produce a `mapping`/`speakingTimes` set
        /// that compares byte-equal to the previous run (same speaker count,
        /// same matcher output) — without a fresh marker, the naming view's
        /// per-presentation reset never fires and consecutive Re-run clicks
        /// are silently swallowed by the `completedJobID` guard. Excluded
        /// from CodingKeys so disk reloads regenerate it.
        var revision: UUID = .init()

        private enum CodingKeys: String, CodingKey {
            case jobID, meetingTitle, mapping, speakingTimes, embeddings,
                 audioPath, segments, participants, isDualSource
        }

        struct Segment: Codable {
            let start: TimeInterval
            let end: TimeInterval
            let speaker: String
        }
    }

    /// Result from the speaker naming popup.
    enum SpeakerNamingResult {
        case confirmed([String: String]) // user confirmed with mapping
        case rerun(Int) // re-run diarization with N speakers
        case skipped // user skipped
    }

    /// RAM cache of naming data, rebuilt from disk on loadSnapshot().
    /// Internal setter allows test access via @testable import.
    var speakerNamingDataByJob: [UUID: SpeakerNamingData] = [:]

    /// Per-job snapshot of the auto-name suggestions shown in the dialog,
    /// kept until the user confirms/skips so `recordRecognition` can write
    /// the JSONL row. Cleared on completion. Not persisted across launches —
    /// if the user confirms in a fresh session, the recognition log row will
    /// have nil/empty `autoName` (acceptable; user data is the real signal).
    private var stashedSuggestedAtDialog: [UUID: [String: String]] = [:]
    private var stashedTopCandidates: [UUID: [String: [TopCandidate]]] = [:]

    /// The currently displayed naming data (first pending item).
    var pendingSpeakerNaming: SpeakerNamingData? {
        guard let firstPendingJob = pendingSpeakerNamingJobs.first else { return nil }
        return speakerNamingDataByJob[firstPendingJob.id]
    }

    /// Filesystem slug for a job's persisted artefacts (`<slug>_naming.json`,
    /// `<slug>_16k.wav`, `<slug>_segments.json`, mix/app/mic WAVs). Embedding
    /// the job's short-id keeps two back-to-back same-title meetings (e.g. a
    /// recurring "Daily Standup") from clobbering each other on disk and
    /// confusing snapshot rebuild — without it both jobs would resolve to the
    /// same `<title>_naming.json` and the second save would overwrite the
    /// first, then both UUIDs would map to the survivor.
    static func namingSlug(title: String, jobID: UUID) -> String {
        let titleSlug = String(ProtocolGenerator.filename(title: title, ext: "").dropLast())
        return "\(titleSlug)_\(PipelineJob.shortID(for: jobID))"
    }

    /// Returns naming data for a specific job ID, or the first pending job as fallback.
    func speakerNamingData(forJobID jobID: UUID?) -> SpeakerNamingData? {
        if let jobID, let data = speakerNamingDataByJob[jobID] { return data }
        return pendingSpeakerNaming
    }

    /// Jobs in speakerNamingPending state.
    var pendingSpeakerNamingJobs: [PipelineJob] {
        jobs.filter { $0.state == .speakerNamingPending }
    }

    /// Called by the UI when the user confirms, skips, or re-runs speaker naming.
    /// Always handles "late" completion — the pipeline never blocks on naming.
    func completeSpeakerNaming(jobID: UUID, result: SpeakerNamingResult) {
        guard let data = speakerNamingDataByJob[jobID] else { return }
        let slug = jobs.first { $0.id == jobID }?.namingSlug

        switch result {
        case let .confirmed(userMapping):
            recordRecognition(
                jobID: jobID, title: data.meetingTitle,
                userMapping: userMapping, fallback: data.mapping,
            )
            // Transition out of .speakerNamingPending synchronously so the
            // UI's close-when-empty check sees the change immediately. The
            // transcript rewrite + protocol generation happens async below.
            if let idx = jobs.firstIndex(where: { $0.id == jobID }),
               jobs[idx].state == .speakerNamingPending {
                updateJobState(id: jobID, to: .generatingProtocol)
            }
            Task { await reapplySpeakerNames(jobID: jobID, mapping: userMapping) }

        case let .rerun(count):
            Task { await lateDiarization(jobID: jobID, speakerCount: count) }

        case .skipped:
            recordRecognition(
                jobID: jobID, title: data.meetingTitle,
                userMapping: nil, fallback: data.mapping,
            )
            acceptAutoNames(jobID: jobID, slug: slug)
        }
    }

    /// Pull stashed forensics for a job and write the recognition-stats row.
    /// Falls back to the original SpeakerNamingData mapping when the stash is
    /// missing (e.g. the user confirmed in a fresh app session).
    private func recordRecognition(
        jobID: UUID, title: String,
        // swiftlint:disable:next discouraged_optional_collection
        userMapping: [String: String]?, fallback: [String: String],
    ) {
        recordRecognition(
            suggested: stashedSuggestedAtDialog[jobID] ?? fallback,
            userMapping: userMapping,
            topCandidates: stashedTopCandidates[jobID] ?? [:],
            jobID: jobID,
            title: title,
        )
    }

    /// Skipped or stale-cleanup path: the user accepted (implicitly or by
    /// timeout) the auto-names. Drops sidecar files synchronously, transitions
    /// to .done. If a protocol generator is configured AND the transcript file
    /// exists, fires off protocol generation in the background; the job
    /// transitions through .generatingProtocol → .done as that completes.
    private func acceptAutoNames(jobID: UUID, slug: String?) {
        // Probe the factory's actual output, not just its existence — the
        // closure is wired even when protocolProvider is `.none`, but
        // returns nil. Without this, the Task path below fizzles silently
        // (generateProtocol guards on factory()) and the job sits in
        // .speakerNamingPending forever.
        let canGenerateProtocol = (protocolGeneratorFactory?() != nil)
            && outputDir != nil
            && jobs.first { $0.id == jobID }?.transcriptPath != nil

        removeNamingData(jobID: jobID, slug: slug)

        if canGenerateProtocol {
            Task { await generateProtocolForExistingJob(jobID: jobID) }
        } else if let idx = jobs.firstIndex(where: { $0.id == jobID }),
                  jobs[idx].state == .speakerNamingPending {
            updateJobState(id: jobID, to: .done)
        }
    }

    private func generateProtocolForExistingJob(jobID: UUID) async {
        guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }),
              let transcriptPath = jobs[jobIndex].transcriptPath,
              let outputDir,
              let transcript = try? String(contentsOf: transcriptPath, encoding: .utf8)
        else { return }
        await generateProtocol(
            jobID: jobID,
            transcript: transcript,
            title: jobs[jobIndex].meetingTitle,
            protocolsDir: outputDir.appendingPathComponent("protocols"),
        )
        if let idx = jobs.firstIndex(where: { $0.id == jobID }),
           jobs[idx].state == .generatingProtocol {
            updateJobState(id: jobID, to: .done)
        }
    }

    /// Called by the UI when the user confirms or skips speaker naming.
    func completeSpeakerNaming(result: SpeakerNamingResult) {
        if let jobID = pendingSpeakerNamingJobs.first?.id ?? speakerNamingDataByJob.keys.first {
            completeSpeakerNaming(jobID: jobID, result: result)
        }
    }

    /// Handler for speaker naming. When set, called instead of the default
    /// continuation-based popup. Receives naming data, returns result.
    /// Used by tests to auto-complete without UI interaction.
    var speakerNamingHandler: ((SpeakerNamingData) async -> SpeakerNamingResult)?

    /// Default factory for `speakerMatcherFactory`: a matcher that writes to a
    /// throwaway tmp path. Production callers (AppState) MUST inject an explicit
    /// factory pointing at the real `speakers.json`. This keeps the user's real
    /// DB safe from any test that constructs a PipelineQueue without injection.
    nonisolated static func throwawayMatcherFactory() -> () -> SpeakerMatcher {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineQueue-throwaway-\(UUID().uuidString).json")
        return { SpeakerMatcher(dbPath: path) }
    }

    /// Simple init for skeleton tests and basic queue usage.
    init(
        logDir: URL? = nil,
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = PipelineQueue.throwawayMatcherFactory(),
        completedJobLifetime: TimeInterval = 60,
    ) {
        self.logDir = logDir ?? AppPaths.ipcDir
        self.engine = nil
        self.diarizationFactory = nil
        self.protocolGeneratorFactory = nil
        self.outputDir = nil
        self.diarizeEnabled = false
        self.numSpeakers = 0
        self.micLabel = "Me"
        self.speakerMatcherFactory = speakerMatcherFactory
        self.vadConfig = nil
        self.recognitionStatsLog = nil
        self.completedJobLifetime = completedJobLifetime
    }

    // MARK: - Known speaker names (issue #155)

    //
    // Cached snapshot of speaker names for the SpeakerNamingView's
    // "known voices" chip row. SwiftUI re-evaluates view bodies often
    // (every keystroke / hover / @State change in any sub-view), so
    // doing the work in the body — `speakerMatcherFactory().allSpeakerNames()`
    // — re-opens speakers.json and re-decodes every embedding per render.
    // With ~37 embeddings the main thread pinned at 100% CPU after
    // extended uptime (issue #155).
    //
    // The cache is refreshed on init and after every code path that
    // mutates the on-disk DB (recognition outcomes, rename, delete,
    // merge). UI reads `knownSpeakerNames` directly with zero I/O.

    private(set) var knownSpeakerNames: [String] = []

    func refreshKnownSpeakerNames() {
        let next = speakerMatcherFactory().allSpeakerNames()
        // Compare-before-assign: @Observable fires SwiftUI invalidations on
        // every set, even when the value is identical. The factory + decode
        // already happened at this point, but skipping the assign keeps
        // downstream view bodies from re-rendering unnecessarily.
        guard next != knownSpeakerNames else { return }
        knownSpeakerNames = next
    }

    /// Apply a speaker DB update via the matcher AND refresh the cached
    /// names in one step. Use instead of calling `matcher.updateDB(...)` +
    /// `refreshKnownSpeakerNames()` separately at internal pipeline sites.
    private func updateSpeakerDB(
        matcher: SpeakerMatcher,
        mapping: [String: String],
        embeddings: [String: [Float]],
        speakingTimes: [String: TimeInterval] = [:],
    ) {
        matcher.updateDB(
            mapping: mapping,
            embeddings: embeddings,
            speakingTimes: speakingTimes,
        )
        refreshKnownSpeakerNames()
    }

    /// Full init with all processing dependencies.
    init(
        engine: any TranscribingEngine,
        diarizationFactory: @escaping () -> any DiarizationProvider,
        protocolGeneratorFactory: @escaping () -> (any ProtocolGenerating)?,
        outputDir: URL,
        logDir: URL? = nil,
        diarizeEnabled: Bool = false,
        numSpeakers: Int = 0,
        micLabel: String = "Me",
        speakerMatcherFactory: @escaping () -> SpeakerMatcher = PipelineQueue.throwawayMatcherFactory(),
        vadConfig: VADConfig? = nil,
        recognitionStatsLog: RecognitionStatsLog? = nil,
        completedJobLifetime: TimeInterval = 60,
    ) {
        self.logDir = logDir ?? AppPaths.ipcDir
        self.engine = engine
        self.diarizationFactory = diarizationFactory
        self.protocolGeneratorFactory = protocolGeneratorFactory
        self.outputDir = outputDir
        self.diarizeEnabled = diarizeEnabled
        self.numSpeakers = numSpeakers
        self.micLabel = micLabel
        self.speakerMatcherFactory = speakerMatcherFactory
        self.vadConfig = vadConfig
        self.recognitionStatsLog = recognitionStatsLog
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
        saveSnapshot()
        logger.info("Enqueued job: \(job.meetingTitle) (\(job.id))")
        triggerProcessing()
    }

    /// Test-only: insert a fully-formed job at any state, bypassing
    /// `enqueue()` and the processing trigger. Lets snapshot/observer tests
    /// exercise terminal states (`.done`, `.error`) without spinning real
    /// engines. Production code MUST go through `enqueue()`.
    func insertJobForTesting(_ job: PipelineJob) {
        jobs.append(job)
    }

    /// Wait for the queue to drain: any in-flight processing finishes and no
    /// jobs remain in `.waiting`. Used by tests that enqueue a job and need to
    /// observe a terminal state without racing against the spawned process task
    /// from `enqueue` → `triggerProcessing()`.
    func awaitProcessing() async {
        while isProcessing || !pendingJobs.isEmpty {
            if let task = processTask {
                await task.value
            } else {
                // processTask not yet assigned — yield so the spawning Task
                // can run.
                await Task.yield()
            }
        }
    }

    func removeJob(id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            markProcessed(mixPath: jobs[index].mixPath)
            jobs.remove(at: index)
        }
        saveSnapshot()
    }

    /// Cancel a job. Removes the job + cleans up sidecar files if naming was
    /// pending. Done/error jobs are not affected.
    func cancelJob(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let state = jobs[index].state
        let slug = jobs[index].namingSlug
        switch state {
        case .waiting:
            jobs.remove(at: index)
            saveSnapshot()

        case .transcribing, .diarizing, .generatingProtocol:
            cancelledJobIDs.insert(id)
            processTask?.cancel()
            removeNamingData(jobID: id, slug: slug)
            jobs.remove(at: index)
            saveSnapshot()

        case .speakerNamingPending:
            // User cancelled while waiting for late-confirm — drop the sidecar
            // files and the in-memory state so it doesn't sit around.
            removeNamingData(jobID: id, slug: slug)
            jobs.remove(at: index)
            saveSnapshot()

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
        saveSnapshot()
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
        guard !jobs[index].warnings.contains(message) else { return }
        jobs[index].warnings.append(message)
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
    func processNext() async { // swiftlint:disable:this function_body_length cyclomatic_complexity
        guard let index = jobs.firstIndex(where: { $0.state == .waiting }) else {
            isProcessing = false
            return
        }
        guard let engine, let outputDir else {
            logger.warning("Processing dependencies not configured — skipping")
            isProcessing = false
            return
        }
        let jobID = jobs[index].id
        let shortID = jobs[index].shortID
        let title = jobs[index].meetingTitle
        let mixPath = jobs[index].mixPath
        let appPath = jobs[index].appPath
        let micPath = jobs[index].micPath
        let micDelay = jobs[index].micDelay
        let participants = jobs[index].participants

        do {
            // --- Transcription ---
            updateJobState(id: jobID, to: .transcribing)
            startElapsedTimer()
            logger.info("[\(shortID, privacy: .public)] transcription_start title=\(title, privacy: .private)")

            // Create a temp directory for intermediate 16kHz files
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pipeline_\(jobID.uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }

            // Compute slug early so it's available for persisted file names
            let slug = Self.namingSlug(title: title, jobID: jobID)

            let transcript: String
            // Segments cached for potential diarization reuse (avoids double transcription)
            var cachedSegments: [TimestampedSegment]? // swiftlint:disable:this discouraged_optional_collection
            let isDualSource = appPath != nil && micPath != nil
            if let appAudioPath = appPath, let micAudioPath = micPath {
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
                    micDelay: micDelay,
                    micLabel: micLabel,
                )
                cachedSegments = segments
                transcript = segments.map(\.formattedLine).joined(separator: "\n")
            } else {
                // Single-source: resample mix to 16kHz
                guard let mixPath else {
                    throw NSError(
                        domain: "PipelineQueue", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Single-source job missing mixPath"],
                    )
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
            logger.info(
                "[\(shortID, privacy: .public)] transcription_complete segments=\(segCount, privacy: .public) duration=\(totalSecs, privacy: .public)s",
            )

            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Compute input RMS only on the failure path — loading the whole
                // mix file is expensive (~MB-per-minute) and we only need it when
                // diagnosing why transcription produced nothing. Paired imports
                // without a real mix file report NaN (RMS unavailable).
                let inputRMS = mixPath.flatMap { AudioMixer.rmsDecibels(forFileAt: $0) } ?? .nan
                logger.warning(
                    "[\(shortID, privacy: .public)] transcription_empty inputRMSdBFS=\(inputRMS, privacy: .public). Likely silent input or ASR misconfiguration — check microphone level and engine settings.",
                )
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
                    startElapsedTimer()

                    // Use mix audio for diarization (already resampled in single-source path).
                    // Paired imports without a real `_mix.wav` source mix `app + mic`
                    // directly into the workdir cache — no persistent mix file written.
                    let mix16k = workDir.appendingPathComponent("mix_16k.wav")
                    if !FileManager.default.fileExists(atPath: mix16k.path) {
                        if let mixPath, FileManager.default.fileExists(atPath: mixPath.path) {
                            try await AudioMixer.resampleFile(from: mixPath, to: mix16k)
                        } else if let appAudioPath = appPath, let micAudioPath = micPath {
                            try AudioMixer.mix(
                                appAudioPath: appAudioPath, micAudioPath: micAudioPath,
                                outputPath: mix16k, micDelay: micDelay,
                                sampleRate: AudioConstants.targetSampleRate,
                            )
                        } else {
                            throw NSError(
                                domain: "PipelineQueue", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "No mix audio available for diarization"],
                            )
                        }
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
                                // Diarize app and mic tracks separately. Mic
                                // failures (silent track on Mac mini hosts
                                // without a real input device, etc.) are
                                // tolerated — fall back to app-only.
                                let app16k = workDir.appendingPathComponent("app_16k.wav")
                                let mic16k = workDir.appendingPathComponent("mic_16k.wav")

                                appDiarization = try await diarizeProcess.run(
                                    audioPath: app16k,
                                    numSpeakers: speakerCount,
                                    meetingTitle: title,
                                )
                                do {
                                    micDiarization = try await diarizeProcess.run(
                                        audioPath: mic16k,
                                        numSpeakers: nil, // auto-detect local speakers
                                        meetingTitle: title,
                                    )
                                } catch {
                                    logger.warning(
                                        "[\(shortID, privacy: .public)] mic_diarization_failed error=\(error.localizedDescription, privacy: .public) — falling back to app-only diarization",
                                    )
                                    addWarning(id: jobID, "Mic track diarization failed — speaker labels reflect remote audio only")
                                    micDiarization = nil
                                }

                                if let micDiar = micDiarization {
                                    // Merge for speaker naming (prefixed IDs: R_, M_)
                                    // swiftlint:disable force_unwrapping
                                    diarization = DiarizationProcess.mergeDualTrackDiarization(
                                        appDiarization: appDiarization!,
                                        micDiarization: micDiar,
                                        // swiftlint:enable force_unwrapping
                                    )
                                } else {
                                    // App-only fallback. Feeds the speaker-naming
                                    // loop below; the dual-track-app-only branch in
                                    // the assignment block then keeps mic segments
                                    // with their raw `micLabel` instead of forcing
                                    // them through speaker matching.
                                    diarization = appDiarization
                                }
                            } else {
                                diarization = try await diarizeProcess.run(
                                    audioPath: mix16k,
                                    numSpeakers: speakerCount,
                                    meetingTitle: title,
                                )
                            }

                            guard let currentDiarization = diarization else { break }
                            autoNames = currentDiarization.autoNames

                            guard let embeddings = currentDiarization.embeddings else { break }

                            let matcher = speakerMatcherFactory()
                            let verbose = matcher.matchVerbose(embeddings: embeddings)
                            let matched = verbose.mapValues(\.assignedName)
                            autoNames = matched
                            let topCandidates = verbose.mapValues(\.topCandidates)

                            // Pre-match participants to remaining speakers
                            if !participants.isEmpty {
                                autoNames = SpeakerMatcher.preMatchParticipants(
                                    mapping: autoNames,
                                    speakingTimes: currentDiarization.speakingTimes,
                                    participants: participants,
                                )
                            }

                            let suggestedAtDialog = autoNames
                            let autoMatched = matched.count { $0.key != $0.value }
                            let unknown = matched.count - autoMatched
                            logger.info(
                                "[recognition] \(matched.count) speakers, \(autoMatched) auto, \(unknown) unknown",
                            )

                            // Use persisted 16kHz path (survives workDir cleanup)
                            let recordingsDir = outputDir.appendingPathComponent("recordings")
                            let persistedAudioPath = recordingsDir.appendingPathComponent("\(slug)_16k.wav")

                            let namingData = SpeakerNamingData(
                                jobID: jobID,
                                meetingTitle: title,
                                mapping: autoNames,
                                speakingTimes: currentDiarization.speakingTimes,
                                embeddings: embeddings,
                                audioPath: persistedAudioPath,
                                segments: currentDiarization.segments.map { seg in
                                    SpeakerNamingData.Segment(start: seg.start, end: seg.end, speaker: seg.speaker)
                                },
                                participants: participants,
                                isDualSource: isDualSource,
                            )

                            // Persist naming data and set slug early
                            saveNamingData(namingData, slug: slug)
                            if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
                                jobs[idx].namingSlug = slug
                            }

                            stopElapsedTimer()

                            // Stash recognition forensics on the job so the late-confirm
                            // path can write the JSONL row when the user actually
                            // confirms (which may be later via the re-openable dialog).
                            stashedSuggestedAtDialog[jobID] = suggestedAtDialog
                            stashedTopCandidates[jobID] = topCandidates

                            // Non-blocking: allow test handler to confirm synchronously,
                            // otherwise proceed with auto-names immediately.
                            // User can confirm/re-run later via the naming dialog.
                            if let handler = speakerNamingHandler {
                                let namingResult = await handler(namingData)
                                switch namingResult {
                                case let .confirmed(userMapping):
                                    for (label, name) in userMapping where !name.isEmpty {
                                        autoNames[label] = name
                                    }
                                    updateSpeakerDB(
                                        matcher: matcher,
                                        mapping: autoNames,
                                        embeddings: embeddings,
                                        speakingTimes: currentDiarization.speakingTimes,
                                    )
                                    recordRecognition(
                                        suggested: suggestedAtDialog,
                                        userMapping: userMapping,
                                        topCandidates: topCandidates,
                                        jobID: jobID, title: title,
                                    )
                                    removeNamingData(jobID: jobID, slug: nil)

                                case let .rerun(count):
                                    speakerCount = count
                                    updateJobState(id: jobID, to: .diarizing)
                                    startElapsedTimer()
                                    logger.info("Re-running diarization with \(count) speakers")
                                    continue diarizationLoop

                                case .skipped:
                                    break
                                }
                            } else {
                                // Production: stash data, don't block pipeline. Notification
                                // is posted later — after the job transitions to
                                // .speakerNamingPending — so the window's onAppear
                                // doesn't auto-close it on a state mismatch.
                                speakerNamingDataByJob[jobID] = namingData
                            }
                            break diarizationLoop
                        }

                        // Apply speaker names to segments
                        if useDualTrack, let appDiar = appDiarization, let micDiar = micDiarization,
                           let cached = cachedSegments {
                            // Dual-track: assign from respective diarizations
                            let namedAppDiar = DiarizationResult(
                                segments: appDiar.segments,
                                speakingTimes: appDiar.speakingTimes,
                                autoNames: DiarizationProcess.unprefixNames(autoNames, prefix: "R_"),
                                embeddings: appDiar.embeddings,
                            )
                            let namedMicDiar = DiarizationResult(
                                segments: micDiar.segments,
                                speakingTimes: micDiar.speakingTimes,
                                autoNames: DiarizationProcess.unprefixNames(autoNames, prefix: "M_"),
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
                        } else if useDualTrack, let appDiar = appDiarization, let cached = cachedSegments {
                            // Mic diarization failed (silent track / no input
                            // device). Diarize the app track normally and keep
                            // the mic transcript with its raw `micLabel` —
                            // better than emitting "speakers not identified"
                            // on a recording that has perfectly good remote
                            // audio.
                            let namedAppDiar = DiarizationResult(
                                segments: appDiar.segments,
                                speakingTimes: appDiar.speakingTimes,
                                autoNames: DiarizationProcess.unprefixNames(autoNames, prefix: "R_"),
                                embeddings: appDiar.embeddings,
                            )
                            let appSegs = cached.filter { $0.speaker == "Remote" }
                            let micSegs = cached.filter { $0.speaker == micLabel }
                            let labeledApp = DiarizationProcess.assignSpeakers(
                                transcript: appSegs, diarization: namedAppDiar,
                            )
                            // micSegs keep their original micLabel speaker tag.
                            let combined = (labeledApp + micSegs).sorted { $0.start < $1.start }
                            let merged = DiarizationProcess.mergeConsecutiveSpeakers(combined)
                            finalTranscript = merged.map(\.formattedLine).joined(separator: "\n")
                        } else if let currentDiarization = diarization {
                            // Single-source: standard assignment
                            let namedDiarization = DiarizationResult(
                                segments: currentDiarization.segments,
                                speakingTimes: currentDiarization.speakingTimes,
                                autoNames: autoNames,
                                embeddings: currentDiarization.embeddings,
                            )
                            let segments: [TimestampedSegment] = if let cached = cachedSegments {
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
                        }
                        let segCount = diarization?.segments.count ?? 0
                        logger.info("[\(shortID, privacy: .public)] diarization_complete segments=\(segCount, privacy: .public)")
                    } catch {
                        logger.warning("[\(shortID, privacy: .public)] diarization_failed error=\(error.localizedDescription, privacy: .public)")
                        addWarning(id: jobID, "Diarization failed — speakers not identified")
                        // Continue with original transcript
                    }
                } else {
                    logger.info("[\(shortID, privacy: .public)] diarization_skipped")
                }
            }

            // --- Save Transcript & Audio (always) ---
            let protocolsDir = outputDir.appendingPathComponent("protocols")
            let txtPath = try ProtocolGenerator.saveTranscript(finalTranscript, title: title, dir: protocolsDir)
            logger.info("[\(shortID, privacy: .public)] transcript_saved file=\(txtPath.lastPathComponent, privacy: .public)")

            if let idx = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[idx].transcriptPath = txtPath
                jobs[idx].namingSlug = slug
            }

            let recordingsDir = outputDir.appendingPathComponent("recordings")
            Self.copyAudioToOutput(
                mixPath: mixPath, appPath: appPath, micPath: micPath,
                title: title, outputDir: recordingsDir,
            )

            // --- Persist 16kHz audio for re-diarization (move instead of copy to avoid double I/O) ---
            try? FileManager.default.moveItem(
                at: workDir.appendingPathComponent("mix_16k.wav"),
                to: recordingsDir.appendingPathComponent("\(slug)_16k.wav"),
            )

            if isDualSource {
                for (name, suffix) in [("app_16k.wav", "_app_16k.wav"), ("mic_16k.wav", "_mic_16k.wav")] {
                    try? FileManager.default.moveItem(
                        at: workDir.appendingPathComponent(name),
                        to: recordingsDir.appendingPathComponent("\(slug)\(suffix)"),
                    )
                }
            }

            // --- Persist transcript segments for late re-assignment ---
            if let cachedSegments {
                let segPath = recordingsDir.appendingPathComponent("\(slug)_segments.json")
                if let data = try? JSONEncoder().encode(cachedSegments) {
                    try? data.write(to: segPath, options: .atomic)
                }
            }

            // --- Protocol Generation (optional) ---
            // Skip when naming is pending — protocol will be generated on
            // confirm (with the right names) or on skip/stale-cleanup (with
            // the current auto-names). Saves an LLM call we'd otherwise
            // have to redo.
            if speakerNamingDataByJob[jobID] == nil {
                await generateProtocol(
                    jobID: jobID, transcript: finalTranscript, title: title,
                    protocolsDir: protocolsDir,
                )
            }

            stopElapsedTimer()
            if speakerNamingDataByJob[jobID] != nil {
                updateJobState(id: jobID, to: .speakerNamingPending)
                // Auto-pop the dialog now that the job is in the right state.
                // The window's onAppear guard reads pendingSpeakerNamingJobs,
                // which only includes .speakerNamingPending jobs, so the
                // notification has to come after the transition above.
                NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)
            } else {
                updateJobState(id: jobID, to: .done)
            }
        } catch is CancellationError {
            stopElapsedTimer()
            logger.info("Job \(jobID) cancelled")
            // Job already removed by cancelJob()
        } catch {
            stopElapsedTimer()
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

    // MARK: - Protocol generation

    /// Run the LLM protocol generator over a transcript, save the .md file,
    /// stash its path on the job. No-op if no protocol generator is configured.
    /// Used by: main pipeline (if no naming pending), reapplySpeakerNames
    /// (after confirm), skipped/stale paths (with current auto-names).
    private func generateProtocol(
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
            logger.info("[\(shortID, privacy: .public)] protocol_saved file=\(mdPath.lastPathComponent, privacy: .public)")
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

    // MARK: - Late re-apply speaker names

    /// Late-confirm path: read the saved transcript, replace generic speaker
    /// labels with user-provided names, update the matcher DB, regenerate the
    /// protocol with the correct names.
    private func reapplySpeakerNames(jobID: UUID, mapping: [String: String]) async {
        guard let namingData = speakerNamingDataByJob[jobID],
              let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        let slug = jobs[jobIndex].namingSlug

        // Update speaker matcher DB
        let matcher = speakerMatcherFactory()
        var fullMapping = namingData.mapping
        for (label, name) in mapping where !name.isEmpty {
            fullMapping[label] = name
        }
        updateSpeakerDB(
            matcher: matcher,
            mapping: fullMapping,
            embeddings: namingData.embeddings,
        )

        if let transcriptPath = jobs[jobIndex].transcriptPath {
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

                if let outputDir {
                    await generateProtocol(
                        jobID: jobID,
                        transcript: transcript,
                        title: jobs[jobIndex].meetingTitle,
                        protocolsDir: outputDir.appendingPathComponent("protocols"),
                    )
                }
            } catch {
                logger.error("Failed to re-apply speaker names: \(error)")
            }
        }

        removeNamingData(jobID: jobID, slug: slug)
        updateJobState(id: jobID, to: .done)
    }

    // MARK: - Late Re-diarization

    /// Re-run diarization from persisted 16kHz audio after pipeline completed.
    private func lateDiarization(jobID: UUID, speakerCount: Int) async {
        guard let namingData = speakerNamingDataByJob[jobID],
              let jobIndex = jobs.firstIndex(where: { $0.id == jobID }),
              let diarizationFactory,
              let slug = jobs[jobIndex].namingSlug,
              let outputDir else {
            logger.warning("Cannot re-diarize: missing data or configuration")
            return
        }

        let recordingsDir = outputDir.appendingPathComponent("recordings")
        let diarizeProcess = diarizationFactory()
        guard diarizeProcess.isAvailable else {
            logger.warning("Diarization not available for late re-run")
            return
        }

        updateJobState(id: jobID, to: .diarizing)
        startElapsedTimer()

        do {
            let title = jobs[jobIndex].meetingTitle
            let diarization: DiarizationResult

            if namingData.isDualSource {
                let app16k = recordingsDir.appendingPathComponent("\(slug)_app_16k.wav")
                let mic16k = recordingsDir.appendingPathComponent("\(slug)_mic_16k.wav")
                async let appDiar = diarizeProcess.run(
                    audioPath: app16k, numSpeakers: speakerCount, meetingTitle: title,
                )
                async let micDiar = diarizeProcess.run(
                    audioPath: mic16k, numSpeakers: nil, meetingTitle: title,
                )
                diarization = try await DiarizationProcess.mergeDualTrackDiarization(
                    appDiarization: appDiar, micDiarization: micDiar,
                )
            } else {
                let mix16k = recordingsDir.appendingPathComponent("\(slug)_16k.wav")
                diarization = try await diarizeProcess.run(
                    audioPath: mix16k, numSpeakers: speakerCount, meetingTitle: title,
                )
            }

            stopElapsedTimer()

            guard let newNamingData = buildNamingData(
                jobID: jobID, title: title,
                diarization: diarization, prior: namingData,
            ) else {
                logger.warning("Late re-diarization produced no embeddings")
                updateJobState(id: jobID, to: .speakerNamingPending)
                return
            }

            // Update disk + RAM
            speakerNamingDataByJob[jobID] = newNamingData
            saveNamingData(newNamingData, slug: slug)

            // Show naming dialog again
            updateJobState(id: jobID, to: .speakerNamingPending)
            NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)

            // If test handler is set, call it directly
            if let handler = speakerNamingHandler {
                let result = await handler(newNamingData)
                completeSpeakerNaming(jobID: jobID, result: result)
            }
        } catch {
            logger.error("Late re-diarization failed: \(error)")
            stopElapsedTimer()
            updateJobState(id: jobID, to: .speakerNamingPending)
        }
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

    // MARK: - Speaker Naming Persistence

    func saveNamingData(_ data: SpeakerNamingData, slug: String) {
        guard let outputDir else { return }
        let recordingsDir = outputDir.appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let path = recordingsDir.appendingPathComponent("\(slug)_naming.json")
        do {
            // FluidAudio embeddings can contain NaN/Inf for short or silent
            // segments. Default JSON encoder rejects them — use the string
            // round-trip strategy so the data still makes it to disk.
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "Infinity",
                negativeInfinity: "-Infinity",
                nan: "NaN",
            )
            let json = try encoder.encode(data)
            try json.write(to: path, options: .atomic)
        } catch {
            // Silent failure here means late-confirm won't work after a
            // restart. Make it visible: log + warning on the job.
            logger.error("Failed to save naming data: \(error.localizedDescription)")
            addWarning(id: data.jobID, "Late re-confirm unavailable — naming data could not be persisted")
        }
    }

    func loadNamingData(slug: String) -> SpeakerNamingData? {
        guard let outputDir else { return nil }
        let path = outputDir.appendingPathComponent("recordings/\(slug)_naming.json")
        guard let json = try? Data(contentsOf: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN",
        )
        return try? decoder.decode(SpeakerNamingData.self, from: json)
    }

    func deleteNamingData(slug: String?) {
        guard let slug, let outputDir else { return }
        let path = outputDir.appendingPathComponent("recordings/\(slug)_naming.json")
        try? FileManager.default.removeItem(at: path)
    }

    /// Remove all naming-related data for a job: RAM caches, disk JSON, and
    /// sidecar files. Also clears the recognition-stats stash dicts so they
    /// don't leak across rerun / stale-cleanup paths.
    private func removeNamingData(jobID: UUID, slug: String?) {
        speakerNamingDataByJob.removeValue(forKey: jobID)
        stashedSuggestedAtDialog.removeValue(forKey: jobID)
        stashedTopCandidates.removeValue(forKey: jobID)
        deleteNamingData(slug: slug)
        cleanupSidecarFiles(slug: slug)
    }

    /// Delete 16kHz audio and segment sidecar files for a slug.
    func cleanupSidecarFiles(slug: String?) {
        guard let slug, let outputDir else { return }
        let recordingsDir = outputDir.appendingPathComponent("recordings")
        let suffixes = ["_16k.wav", "_app_16k.wav", "_mic_16k.wav", "_segments.json"]
        for suffix in suffixes {
            let path = recordingsDir.appendingPathComponent("\(slug)\(suffix)")
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// Auto-resolve pending naming items older than maxAge (default: 24h).
    /// Generates the protocol with auto-names, transitions them to .done,
    /// deletes sidecar files.
    func cleanupStalePending(maxAge: TimeInterval = 86400) {
        let now = Date()
        for job in jobs where job.state == .speakerNamingPending {
            if now.timeIntervalSince(job.enqueuedAt) > maxAge {
                logger.info("Auto-resolving stale pending naming for \(job.meetingTitle)")
                let jobID = job.id
                let slug = job.namingSlug
                acceptAutoNames(jobID: jobID, slug: slug)
            }
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
            logger.error("Failed to load pipeline snapshot: \(error)")
            return
        }

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

        // Discard jobs whose audio file no longer exists, EXCEPT
        // .speakerNamingPending — those have their own slug-based
        // `_16k.wav` sidecar and don't need the original mix.wav.
        // Paired imports with nil mixPath: keep them — `appPath` is the
        // ground-truth source and it's checked at processNext time.
        loaded.removeAll { job in
            guard let mixPath = job.mixPath else { return false }
            return job.state != .speakerNamingPending
                && !FileManager.default.fileExists(atPath: mixPath.path)
        }

        guard !loaded.isEmpty else {
            logger.info("Snapshot loaded but no recoverable jobs")
            return
        }

        jobs = loaded

        // Rebuild speaker naming cache from disk for .speakerNamingPending jobs
        for job in jobs where job.state == .speakerNamingPending {
            if let slug = job.namingSlug, let data = loadNamingData(slug: slug) {
                speakerNamingDataByJob[job.id] = data
            } else {
                // Naming data lost — transition to done
                logger.warning("Naming data not found for job \(job.id), marking as done")
                if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[idx].state = .done
                }
            }
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
                logger.info("Audio already in output dir, skipping rename: \(src.lastPathComponent)")
                continue
            }
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
        for file in entries where file.lastPathComponent.hasSuffix(RecordingFileSuffix.mix) {
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

        let trackedPaths = Set(jobs.compactMap { $0.mixPath?.standardizedFileURL.path })
        let processedPaths = loadProcessedPaths()
        let now = Date()
        var recovered = 0

        // Orphan recovery requires a `_mix.wav` anchor — pair with companion
        // `_app.wav`/`_mic.wav` tracks when they exist (same stem).
        for group in PairedRecordingResolver.resolve(urls: entries).paired {
            // Orphan recovery requires an on-disk `_mix.wav` anchor — paired
            // groups produced by app+mic synthesis aren't recoverable from the
            // dir scan alone (the synthesized mix lives elsewhere or hasn't
            // been written yet). Skip groups without a real mix file here.
            guard let mixURL = group.mix else { continue }
            let stdPath = mixURL.standardizedFileURL.path

            guard !trackedPaths.contains(stdPath) else { continue }
            guard !processedPaths.contains(stdPath) else { continue }

            let attrs = try? fm.attributesOfItem(atPath: mixURL.path)
            if let created = attrs?[.creationDate] as? Date,
               now.timeIntervalSince(created) > maxAge {
                continue
            }
            // Header-only WAVs are 44 bytes.
            if let size = attrs?[.size] as? Int, size <= 44 {
                continue
            }

            let job = PipelineJob(
                meetingTitle: "Recovered Recording (\(group.stem))",
                appName: "Unknown",
                mixPath: mixURL,
                appPath: group.app,
                micPath: group.mic,
                micDelay: 0,
            )
            jobs.append(job)
            appendLog(jobID: job.id, event: "recovered", from: nil, to: .waiting)
            recovered += 1
        }

        if recovered > 0 {
            saveSnapshot()
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

    /// Record that a job's mix file was successfully processed. Nil mixPath
    /// (paired imports without a `_mix.wav` source) is a no-op — there's no
    /// path to track for orphan recovery.
    func markProcessed(mixPath: URL?) {
        guard let mixPath else { return }
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

    func saveSnapshot() {
        do {
            ensureLogDir()
            try PipelineSnapshot.save(jobs, to: logDir)
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

    /// Build recognition events and persist them off the pipeline path. Logs
    /// outcome counts immediately; JSONL append runs in a detached Task.
    private func recordRecognition(
        suggested: [String: String],
        // swiftlint:disable:next discouraged_optional_collection
        userMapping: [String: String]?,
        topCandidates: [String: [TopCandidate]],
        jobID: UUID,
        title: String,
    ) {
        let events = RecognitionStats.buildEvents(
            suggested: suggested, userMapping: userMapping,
            topCandidates: topCandidates,
            jobID: jobID, meetingTitle: title,
        )
        var counts: [RecognitionAction: Int] = [:]
        for e in events {
            counts[e.action, default: 0] += 1
        }
        let parts = RecognitionAction.allCases
            .map { "\($0.rawValue)=\(counts[$0] ?? 0)" }
            .joined(separator: " ")
        logger.info("[recognition] outcome \(parts, privacy: .public)")
        if let recognitionStatsLog {
            Task { await recognitionStatsLog.append(events) }
        }
    }
}
