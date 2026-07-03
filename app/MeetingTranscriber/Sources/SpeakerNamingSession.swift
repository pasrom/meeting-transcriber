import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "SpeakerNamingSession")

/// Collaborator that `PipelineQueue` calls for whatever it still owns while the
/// naming session runs. Strictly id-based (never index-based): a job index goes
/// stale across an `await` when another finished job is evicted by
/// `completedJobLifetime`, a documented past bug — so the session only ever
/// addresses a job by its `UUID`. The queue owns the session strongly
/// (`let naming`); the session holds this delegate weakly, so a deallocated
/// queue turns every delegate call into a harmless no-op (optional chaining)
/// instead of a crash or a retain cycle.
@MainActor
protocol SpeakerNamingSessionDelegate: AnyObject {
    /// A value copy of the job, or nil if it is no longer tracked.
    func job(withID id: UUID) -> PipelineJob?
    func updateJobState(id: UUID, to newState: JobState, error: String?)
    func addWarning(id: UUID, _ message: String)
    /// Persist the per-job naming metadata on the (queue-owned) job. `nil`
    /// for either field means "leave unchanged".
    func setNamingMetadata(jobID: UUID, slug: String?, usedDiarizerMode: DiarizerMode?)
    /// Apply a speaker DB update AND refresh the queue's cached known-names in
    /// one step (issue #155): the write+refresh pairing must stay atomic.
    func updateSpeakerDB(
        matcher: SpeakerMatcher, mapping: [String: String],
        embeddings: [String: [Float]], speakingTimes: [String: TimeInterval],
    )
    /// Run the LLM protocol generator over a transcript (a queue pipeline stage).
    func generateProtocol(jobID: UUID, transcript: String, title: String, protocolsDir: URL) async
    /// Diarize app + mic tracks separately with the shared mic-fail fallback
    /// (a queue pipeline stage, reused by the late re-run).
    func runDualTrackDiarization(
        diarizeProcess: any DiarizationProvider,
        tracks: (app: URL, mic: URL, micDelay: TimeInterval),
        speakerCount: Int?, title: String, jobID: UUID,
    ) async throws -> DiarizationRun
    /// Render the speaker-labeled transcript from a diarization run + cached
    /// transcript segments (a queue pipeline stage, reused by the late rewrite).
    func renderLabeledTranscript(
        run: DiarizationRun, cachedSegments: [TimestampedSegment],
        isDualSource: Bool, autoNames: [String: String],
    ) -> String?
    /// Enter the diarizing stage for a late re-run: `updateJobState(.diarizing)`
    /// + start the menu's elapsed timer.
    func namingStageDidStart(jobID: UUID)
    /// Leave a timed naming stage: stop the elapsed timer.
    func namingStageDidEnd()
}

extension SpeakerNamingSessionDelegate {
    /// Convenience wrapper so call sites that never carry an error message can
    /// omit the `error:` argument.
    func updateJobState(id: UUID, to newState: JobState) {
        updateJobState(id: id, to: newState, error: nil)
    }
}

/// Owns the speaker-naming half of the pipeline: the (possibly late) naming
/// dialog, its persisted sidecars + recognition forensics, and the late
/// re-diarization / re-apply paths. `PipelineQueue` holds this strongly as
/// `let naming` and sets `naming.delegate = self` post-init, so SwiftUI
/// observation follows through the stored property into this nested
/// `@Observable` (the queue exposes thin forwarders for the direct-dict reads
/// at `PipelineController` / `AppState+RPC`).
@MainActor
@Observable
final class SpeakerNamingSession {
    typealias SpeakerNamingData = PipelineQueue.SpeakerNamingData
    typealias SpeakerNamingResult = PipelineQueue.SpeakerNamingResult

    /// The queue. Weak so the queue can own the session strongly with no cycle;
    /// a nil delegate makes every callback a no-op.
    weak var delegate: (any SpeakerNamingSessionDelegate)?

    /// Disk persistence for speaker-naming sidecars (keyed by per-job slug).
    private let namingStore: SpeakerNamingStore
    let speakerMatcherFactory: () -> SpeakerMatcher
    let diarizationFactory: (() -> any DiarizationProvider)?
    /// Optional mode-overriding factory used by `lateDiarization` when the user
    /// picks a different mode in the re-run UI. `nil` = mode override not
    /// supported; `lateDiarization` falls back to `diarizationFactory()`.
    let diarizationFactoryWithMode: ((DiarizerMode) -> any DiarizationProvider)?
    let protocolGeneratorFactory: (() -> (any ProtocolGenerating)?)?
    let outputDir: URL?
    /// nil disables JSONL logging. AppState injects a real instance for
    /// production; tests leave it nil unless they explicitly assert on the log.
    let recognitionStatsLog: RecognitionStatsLog?

    /// RAM cache of naming data, rebuilt from disk on `loadSnapshot()` (via
    /// `restore`). Exposed via a queue forwarder for UI/RPC.
    var speakerNamingDataByJob: [UUID: SpeakerNamingData] = [:]

    /// Handler for speaker naming. When set, called instead of the default
    /// continuation-based popup. Used by tests to auto-complete without UI.
    var speakerNamingHandler: ((SpeakerNamingData) async -> SpeakerNamingResult)?

    /// Per-job snapshot of the auto-name suggestions shown in the dialog, kept
    /// until the user confirms/skips so `recordRecognition` can write the JSONL
    /// row. Cleared on completion. Not persisted across launches — if the user
    /// confirms in a fresh session, the recognition log row will have nil/empty
    /// `autoName` (acceptable; user data is the real signal).
    private var stashedSuggestedAtDialog: [UUID: [String: String]] = [:]
    private var stashedTopCandidates: [UUID: [String: [TopCandidate]]] = [:]

    init(
        namingStore: SpeakerNamingStore,
        speakerMatcherFactory: @escaping () -> SpeakerMatcher,
        diarizationFactory: (() -> any DiarizationProvider)? = nil,
        diarizationFactoryWithMode: ((DiarizerMode) -> any DiarizationProvider)? = nil,
        protocolGeneratorFactory: (() -> (any ProtocolGenerating)?)? = nil,
        outputDir: URL? = nil,
        recognitionStatsLog: RecognitionStatsLog? = nil,
    ) {
        self.namingStore = namingStore
        self.speakerMatcherFactory = speakerMatcherFactory
        self.diarizationFactory = diarizationFactory
        self.diarizationFactoryWithMode = diarizationFactoryWithMode
        self.protocolGeneratorFactory = protocolGeneratorFactory
        self.outputDir = outputDir
        self.recognitionStatsLog = recognitionStatsLog
    }

    // MARK: - Completion

    /// Called by the UI (or the test handler, via the queue forwarder) when the
    /// user confirms, skips, or re-runs speaker naming. Always handles "late"
    /// completion — the pipeline never blocks on naming.
    func completeSpeakerNaming(jobID: UUID, result: SpeakerNamingResult) {
        guard let data = speakerNamingDataByJob[jobID] else { return }
        let slug = delegate?.job(withID: jobID)?.namingSlug

        switch result {
        case let .confirmed(userMapping):
            recordRecognition(
                jobID: jobID, title: data.meetingTitle,
                userMapping: userMapping, fallback: data.mapping,
            )
            // Transition out of .speakerNamingPending synchronously so the UI's
            // close-when-empty check sees the change immediately. This synchronous
            // pending → generatingProtocol hop is the RPC idempotency contract; a
            // duplicate confirm is rejected before it can double-record. The
            // transcript rewrite + protocol generation happen async below.
            if delegate?.job(withID: jobID)?.state == .speakerNamingPending {
                delegate?.updateJobState(id: jobID, to: .generatingProtocol)
            }
            Task { await reapplySpeakerNames(jobID: jobID, mapping: userMapping) }

        case let .rerun(count):
            Task { await lateDiarization(jobID: jobID, speakerCount: count) }

        case let .rerunWithMode(mode, count):
            Task { await lateDiarization(jobID: jobID, speakerCount: count, mode: mode) }

        case .skipped:
            recordRecognition(
                jobID: jobID, title: data.meetingTitle,
                userMapping: nil, fallback: data.mapping,
            )
            acceptAutoNames(jobID: jobID, slug: slug)
        }
    }

    /// Re-invoke the injected naming handler after the job reached
    /// `.speakerNamingPending`. Mirrors the late-rerun re-invocation so the test
    /// path runs the exact same `completeSpeakerNaming` flow the production UI
    /// does. Captures `self` strongly for the op duration (bounded); the delegate
    /// stays weak. No-op when no handler is set (the interactive/production path).
    func invokeHandler(jobID: UUID, data: SpeakerNamingData) {
        guard let handler = speakerNamingHandler else { return }
        Task {
            let result = await handler(data)
            completeSpeakerNaming(jobID: jobID, result: result)
        }
    }

    /// Skipped or stale-cleanup path: the user accepted (implicitly or by
    /// timeout) the auto-names. Drops sidecar files synchronously, transitions
    /// to .done. If a protocol generator is configured AND the transcript file
    /// exists, fires off protocol generation in the background; the job
    /// transitions through .generatingProtocol → .done as that completes.
    private func acceptAutoNames(jobID: UUID, slug: String?) {
        // Probe the factory's actual output, not just its existence — the
        // closure is wired even when protocolProvider is `.none`, but returns
        // nil. Without this, the Task path below fizzles silently
        // (generateProtocol guards on factory()) and the job sits in
        // .speakerNamingPending forever.
        let canGenerateProtocol = (protocolGeneratorFactory?() != nil)
            && outputDir != nil
            && delegate?.job(withID: jobID)?.transcriptPath != nil

        removeNamingData(jobID: jobID, slug: slug)

        if canGenerateProtocol {
            Task { await generateProtocolForExistingJob(jobID: jobID) }
        } else if delegate?.job(withID: jobID)?.state == .speakerNamingPending {
            delegate?.updateJobState(id: jobID, to: .done)
        }
    }

    private func generateProtocolForExistingJob(jobID: UUID) async {
        guard let job = delegate?.job(withID: jobID),
              let transcriptPath = job.transcriptPath,
              let outputDir,
              let transcript = try? String(contentsOf: transcriptPath, encoding: .utf8)
        else { return }
        await delegate?.generateProtocol(
            jobID: jobID,
            transcript: transcript,
            title: job.meetingTitle,
            protocolsDir: outputDir.appendingPathComponent("protocols"),
        )
        if delegate?.job(withID: jobID)?.state == .generatingProtocol {
            delegate?.updateJobState(id: jobID, to: .done)
        }
    }

    // MARK: - Resolve auto-names + park for the dialog

    /// Match a diarization result against the speaker DB, persist naming data +
    /// recognition forensics, and return the auto-name mapping to apply to the
    /// transcript. Parks the job for the (possibly late) naming dialog by
    /// stashing `SpeakerNamingData`; the dialog is driven later by
    /// `completeSpeakerNaming`, so this stage never blocks the pipeline. A job
    /// that opts out via `autoSkipNaming` (headless blocking-transcribe)
    /// finishes on the auto-names without a dialog.
    func resolveSpeakerNames(
        diarization: DiarizationResult,
        job: (jobID: UUID, title: String, slug: String, participants: [String]),
        diarizeProcess: any DiarizationProvider,
        isDualSource: Bool, outputDir: URL,
    ) -> [String: String] {
        let (jobID, title, slug, participants) = job
        // No embeddings → no matching or dialog; keep the diarizer's own names.
        guard let embeddings = diarization.embeddings else { return diarization.autoNames }

        let matcher = speakerMatcherFactory()
        let verbose = matcher.matchVerbose(embeddings: embeddings)
        let matched = verbose.mapValues(\.assignedName)
        var autoNames = matched
        let topCandidates = verbose.mapValues(\.topCandidates)

        // Pre-match participants to remaining speakers.
        if !participants.isEmpty {
            autoNames = SpeakerMatcher.preMatchParticipants(
                mapping: autoNames,
                speakingTimes: diarization.speakingTimes,
                participants: participants,
            )
        }

        let suggestedAtDialog = autoNames
        let autoMatched = matched.count { $0.key != $0.value }
        logger.info("[recognition] \(matched.count) speakers, \(autoMatched) auto, \(matched.count - autoMatched) unknown")

        // Use persisted 16kHz path (survives workDir cleanup).
        let persistedAudioPath = outputDir.appendingPathComponent("recordings")
            .appendingPathComponent("\(slug)_16k.wav")
        let namingData = SpeakerNamingData(
            jobID: jobID,
            meetingTitle: title,
            mapping: autoNames,
            speakingTimes: diarization.speakingTimes,
            embeddings: embeddings,
            audioPath: persistedAudioPath,
            segments: diarization.segments.map { seg in
                SpeakerNamingData.Segment(start: seg.start, end: seg.end, speaker: seg.speaker)
            },
            participants: participants,
            isDualSource: isDualSource,
        )

        // Persist naming data and set slug + mode early.
        saveNamingData(namingData, slug: slug)
        delegate?.setNamingMetadata(jobID: jobID, slug: slug, usedDiarizerMode: diarizeProcess.mode)
        delegate?.namingStageDidEnd()

        // Stash recognition forensics so the late-confirm path can write the
        // JSONL row when the user actually confirms (possibly later, via the
        // re-openable dialog).
        stashedSuggestedAtDialog[jobID] = suggestedAtDialog
        stashedTopCandidates[jobID] = topCandidates

        if delegate?.job(withID: jobID)?.autoSkipNaming == true {
            // Headless blocking-transcribe: accept the auto-assigned names
            // (exactly like a `.skipped` dialog result) so the job finishes on
            // its own. Don't stash naming data: there is no interactive client
            // to resolve it, and parking would wedge the job until the next
            // launch's 24h stale-cleanup.
            return autoNames
        }
        // Production/interactive: stash the naming data so the queue parks the
        // job at `.speakerNamingPending` and pops the (re-openable) dialog. The
        // pipeline continues with the auto-names; the dialog confirms later via
        // `completeSpeakerNaming` without blocking.
        speakerNamingDataByJob[jobID] = namingData
        return autoNames
    }

    // MARK: - Persistence

    /// Persist naming data via `namingStore`, surfacing a per-job warning on
    /// failure (the store stays I/O-only; the session owns the job-state side
    /// effect). A silent failure would mean late-confirm won't work after a
    /// restart, so make it visible: log + warning on the job.
    func saveNamingData(_ data: SpeakerNamingData, slug: String) {
        do {
            try namingStore.save(data, slug: slug)
        } catch {
            // Error left redacted: the write target is `<title-slug>_naming.json`,
            // so a file-write error description would leak the meeting title.
            logger.error("Failed to save naming data: \(error.localizedDescription)")
            delegate?.addWarning(id: data.jobID, "Late re-confirm unavailable — naming data could not be persisted")
        }
    }

    /// Remove all naming-related data for a job: RAM caches, disk JSON, and
    /// sidecar files. Also clears the recognition-stats stash dicts so they
    /// don't leak across rerun / stale-cleanup paths.
    func removeNamingData(jobID: UUID, slug: String?) {
        speakerNamingDataByJob.removeValue(forKey: jobID)
        stashedSuggestedAtDialog.removeValue(forKey: jobID)
        stashedTopCandidates.removeValue(forKey: jobID)
        namingStore.deleteNamingJSON(slug: slug)
        namingStore.cleanupSidecarFiles(slug: slug)
    }

    /// Rebuild the RAM naming cache for a restored `.speakerNamingPending` job
    /// from its on-disk sidecar. Returns false when the sidecar is missing (the
    /// queue then marks the job `.done`). Called from `loadSnapshot`.
    func restore(jobID: UUID, slug: String) -> Bool {
        guard let data = namingStore.load(slug: slug) else { return false }
        speakerNamingDataByJob[jobID] = data
        return true
    }

    /// Auto-resolve pending naming items older than maxAge. Generates the
    /// protocol with auto-names, transitions them to .done, deletes sidecars.
    /// `pendingJobs` is the queue's already-filtered `.speakerNamingPending` list.
    func cleanupStalePending(pendingJobs: [PipelineJob], maxAge: TimeInterval = 86400) {
        let now = Date()
        for job in pendingJobs where now.timeIntervalSince(job.enqueuedAt) > maxAge {
            logger.info("Auto-resolving stale pending naming for \(job.meetingTitle, privacy: .private)")
            acceptAutoNames(jobID: job.id, slug: job.namingSlug)
        }
    }

    // MARK: - Recognition forensics

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
