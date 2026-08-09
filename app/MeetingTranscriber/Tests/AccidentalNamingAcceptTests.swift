@testable import MeetingTranscriber
import XCTest

/// Pins the ways speaker naming can resolve *without* a deliberate user
/// decision, and what trace each of them leaves. Written while triaging a
/// report of the "Name Speakers" window closing on its own with a
/// low-confidence auto-match baked into the protocol (issue #577).
///
/// The report blamed a stray Escape (Skip is bound to it). These tests
/// exercise the non-keyboard paths that produce the same observable outcome,
/// so triage can tell them apart from the log instead of guessing, plus the
/// speaker-DB side effect that makes a stray *Return* worse than a stray
/// Escape.
@MainActor
final class AccidentalNamingAcceptTests: XCTestCase {
    // MARK: - Mock delegate

    /// Minimal `SpeakerNamingSessionDelegate` modelling the queue state the
    /// session reads back. Mirrors the mock in `SpeakerNamingSessionTests`;
    /// kept separate so these tests can assert on speaker-DB writes without
    /// widening that file's mock.
    private final class MockDelegate: SpeakerNamingSessionDelegate {
        var jobs: [UUID: PipelineJob] = [:]
        private(set) var updateSpeakerDBCalls: [[String: String]] = []
        private(set) var generateProtocolCallCount = 0
        /// While true, `generateProtocol` parks after the `.generatingProtocol`
        /// transition, standing in for a slow LLM call so tests can observe the
        /// state the UI sees *during* generation.
        var holdProtocolGeneration = false

        func job(withID id: UUID) -> PipelineJob? {
            jobs[id]
        }

        func updateJobState(id: UUID, to newState: JobState, error _: String?) {
            jobs[id]?.state = newState
        }

        func addWarning(id _: UUID, _: String) {}

        func setNamingMetadata(jobID _: UUID, slug _: String?, usedDiarizerMode _: DiarizerMode?) {}

        func updateSpeakerDB(
            matcher _: SpeakerMatcher, mapping: [String: String],
            embeddings _: [String: [Float]], speakingTimes _: [String: TimeInterval],
        ) {
            updateSpeakerDBCalls.append(mapping)
        }

        /// Mirrors the real `PipelineQueue.generateProtocol`, which flips the job
        /// to `.generatingProtocol` *before* awaiting the LLM
        /// (`PipelineQueue+Stages.swift:664`). That ordering is load-bearing
        /// here: it is what drains `pendingSpeakerNamingJobs`, the list the
        /// naming window's auto-close keys off.
        ///
        /// Deliberately unconditional, unlike the real path, which has two
        /// early returns before the flip (a missing transcript file, and a
        /// protocol factory that turned nil after the probe) — each of which
        /// leaves the job wedged in `.speakerNamingPending` with its sidecars
        /// already deleted. Not modelled here; see the wedge test below.
        func generateProtocol(jobID: UUID, transcript _: String, title _: String, protocolsDir _: URL) async {
            generateProtocolCallCount += 1
            jobs[jobID]?.state = .generatingProtocol
            while holdProtocolGeneration {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        func runDualTrackDiarization(
            diarizeProcess _: any DiarizationProvider,
            tracks _: (app: URL, mic: URL, micDelay: TimeInterval),
            speakerCount _: Int?, title _: String, jobID _: UUID,
        ) throws -> DiarizationRun {
            throw DiarizationError.notAvailable
        }

        func renderLabeledTranscript(
            run _: DiarizationRun, cachedSegments _: [TimestampedSegment],
            isDualSource _: Bool, autoNames _: [String: String],
        ) -> String? {
            nil
        }

        func namingStageDidStart(jobID _: UUID) {}

        func namingStageDidEnd() {}
    }

    // MARK: - Helpers

    private func makeSession(
        outputDir: URL?,
        statsLog: RecognitionStatsLog? = nil,
        withProtocolGenerator: Bool = true,
    ) -> SpeakerNamingSession {
        SpeakerNamingSession(
            namingStore: SpeakerNamingStore(outputDir: nil),
            speakerMatcherFactory: PipelineQueue.throwawayMatcherFactory(),
            protocolGeneratorFactory: withProtocolGenerator ? { MockProtocolGen() } : nil,
            outputDir: outputDir,
            recognitionStatsLog: statsLog,
        )
    }

    /// Auto-matched mapping: the matcher put a real name on the label, which is
    /// exactly the state a stray keystroke would commit.
    private func makeNamingData(jobID: UUID) -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: jobID,
            meetingTitle: "Standup",
            mapping: ["SPEAKER_0": "Alice"],
            speakingTimes: ["SPEAKER_0": 12],
            embeddings: ["SPEAKER_0": [0.1, 0.2, 0.3]],
            audioPath: nil,
            segments: [],
            participants: [],
            isDualSource: false,
        )
    }

    private func pendingJob(transcriptPath: URL?) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Standup", appName: "Test",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.namingSlug = "standup_abcd1234"
        job.transcriptPath = transcriptPath
        return job
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Stale cleanup: the keystroke-free path

    /// `loadSnapshot` runs `cleanupStalePending()` and *then* posts
    /// `.showSpeakerNaming` for whatever is still pending. Stale cleanup drops
    /// the naming data synchronously but leaves the job in
    /// `.speakerNamingPending` for the duration of the async protocol
    /// generation. That combination is what opens the naming window on a job
    /// that has no speaker data left to show — and closes it again, without any
    /// user input, once generation lands.
    func testStaleCleanupLeavesJobPendingWithNoNamingData() async throws {
        let tmp = try makeTempDirectory(prefix: "AccidentalNamingAcceptTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = makeSession(outputDir: tmp)
        let mock = MockDelegate()
        session.delegate = mock

        let job = pendingJob(transcriptPath: transcriptPath)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = makeNamingData(jobID: job.id)

        // maxAge: -1 makes every pending job stale, standing in for the 24 h
        // default without having to forge `enqueuedAt`.
        session.cleanupStalePending(pendingJobs: [job], maxAge: -1)

        // This is the state `loadSnapshot` observes when it decides whether to
        // post `.showSpeakerNaming`: still pending, but nothing left to show.
        // The window therefore opens on the "No speaker data available."
        // placeholder, with no user action involved.
        XCTAssertEqual(mock.jobs[job.id]?.state, .speakerNamingPending)
        XCTAssertNil(session.speakerNamingDataByJob[job.id])

        // ...but the pending list drains as soon as generation *starts*, not
        // when it finishes, because `generateProtocol` flips to
        // `.generatingProtocol` before awaiting the LLM. The window's
        // auto-close is wired to that list, so this path cannot hold a window
        // open for the length of an LLM call. (The wiring itself lives in the
        // scene and is not exercised here — this pins the state it keys off.)
        mock.holdProtocolGeneration = true
        await waitUntil { mock.jobs[job.id]?.state != .speakerNamingPending }
        XCTAssertEqual(mock.jobs[job.id]?.state, .generatingProtocol)
        XCTAssertEqual(mock.generateProtocolCallCount, 1)

        mock.holdProtocolGeneration = false
        await waitUntil { mock.jobs[job.id]?.state == .done }
        XCTAssertEqual(mock.jobs[job.id]?.state, .done)
    }

    /// Stale cleanup calls `acceptAutoNames` directly, bypassing
    /// `recordRecognition`. So the auto-names are committed to the protocol
    /// with no row in the recognition log at all — unlike an explicit Skip.
    /// This asymmetry is the discriminator for triaging a window that closed
    /// on its own.
    func testStaleCleanupWritesNoRecognitionRow() async throws {
        let tmp = try makeTempDirectory(prefix: "AccidentalNamingAcceptTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)
        let logPath = tmp.appendingPathComponent("recognition_log.jsonl")
        let statsLog = RecognitionStatsLog(path: logPath)

        let session = makeSession(outputDir: tmp, statsLog: statsLog)
        let mock = MockDelegate()
        session.delegate = mock

        let job = pendingJob(transcriptPath: transcriptPath)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = makeNamingData(jobID: job.id)

        session.cleanupStalePending(pendingJobs: [job], maxAge: -1)
        await waitUntil { mock.jobs[job.id]?.state == .done }

        // An empty append is a no-op, but it serialises behind anything a
        // regression would already have queued on the actor — so the negative
        // assertion below fails loudly instead of racing past a pending write.
        await statsLog.append([])
        let rows = await statsLog.loadRecent(within: 3600)
        XCTAssertTrue(rows.isEmpty, "stale cleanup left \(rows.count) recognition row(s)")
    }

    /// Control for the test above: an explicit Skip *is* traceable. Every label
    /// is logged `.dismissed`, which is what tells a deliberate Skip apart from
    /// the silent stale-cleanup path.
    func testExplicitSkipWritesDismissedRow() async throws {
        let tmp = try makeTempDirectory(prefix: "AccidentalNamingAcceptTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)
        let logPath = tmp.appendingPathComponent("recognition_log.jsonl")
        let statsLog = RecognitionStatsLog(path: logPath)

        let session = makeSession(outputDir: tmp, statsLog: statsLog)
        let mock = MockDelegate()
        session.delegate = mock

        let job = pendingJob(transcriptPath: transcriptPath)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = makeNamingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .skipped)

        await waitUntil { mock.jobs[job.id]?.state == .done }
        // The JSONL append runs in a detached Task, so poll for the row.
        var rows = await statsLog.loadRecent(within: 3600)
        let deadline = Date().addingTimeInterval(2)
        while rows.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
            rows = await statsLog.loadRecent(within: 3600)
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.action, .dismissed)
    }

    /// `acceptAutoNames` destroys the naming data *before* the protocol task is
    /// guaranteed to transition the job. Its `canGenerateProtocol` probe checks
    /// that `transcriptPath` is non-nil but never that the file exists, while
    /// `generateProtocolForExistingJob` guards on actually reading it. A Skip on
    /// a job whose transcript went missing therefore deletes every sidecar and
    /// then returns without a state change, leaving the job wedged in
    /// `.speakerNamingPending` with nothing left to name and no protocol.
    ///
    /// This documents current behaviour, not desired behaviour: a fix that
    /// makes the cleanup conditional on the transition should flip this test.
    func testSkipWithMissingTranscriptWedgesJobInPendingState() async throws {
        let tmp = try makeTempDirectory(prefix: "AccidentalNamingAcceptTests")
        // Non-nil path, no file behind it — e.g. the transcript was moved or
        // removed between the pipeline writing it and the user deciding.
        let missingTranscript = tmp.appendingPathComponent("gone.txt")

        let session = makeSession(outputDir: tmp)
        let mock = MockDelegate()
        session.delegate = mock

        let job = pendingJob(transcriptPath: missingTranscript)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = makeNamingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .skipped)

        // Give the spawned task every chance to transition the job.
        await waitUntil(
            { mock.jobs[job.id]?.state != .speakerNamingPending }, timeout: 1,
        )

        XCTAssertEqual(
            mock.jobs[job.id]?.state, .speakerNamingPending,
            "job is stuck: cleanup ran but nothing moved it out of pending",
        )
        XCTAssertNil(session.speakerNamingDataByJob[job.id], "naming data is already gone")
        XCTAssertEqual(mock.generateProtocolCallCount, 0, "no protocol was produced either")
    }

    // MARK: - Confirm side effects (why a stray Return is worse)

    /// Skip never touches the speaker DB; Confirm always does — even when the
    /// user changed nothing and the mapping is verbatim the matcher's guess.
    /// So a keystroke that lands on Confirm folds a possibly-wrong embedding
    /// into the stored voice profile, degrading *future* recordings, while the
    /// same keystroke on Skip only affects this one job.
    func testConfirmingUnchangedAutoNamesStillWritesSpeakerDB() async throws {
        let tmp = try makeTempDirectory(prefix: "AccidentalNamingAcceptTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] Alice: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = makeSession(outputDir: tmp)
        let mock = MockDelegate()
        session.delegate = mock

        let job = pendingJob(transcriptPath: transcriptPath)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = makeNamingData(jobID: job.id)

        // Verbatim the auto-mapping — what Confirm submits when nobody edits a
        // field, because the name fields are seeded from the auto-names.
        session.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]))

        await waitUntil { !mock.updateSpeakerDBCalls.isEmpty }
        XCTAssertEqual(mock.updateSpeakerDBCalls.count, 1)
        XCTAssertEqual(mock.updateSpeakerDBCalls.first?["SPEAKER_0"], "Alice")
    }

    func testSkipNeverWritesSpeakerDB() async throws {
        let tmp = try makeTempDirectory(prefix: "AccidentalNamingAcceptTests")
        let transcriptPath = tmp.appendingPathComponent("transcript.txt")
        try "] SPEAKER_0: hello".write(to: transcriptPath, atomically: true, encoding: .utf8)

        let session = makeSession(outputDir: tmp)
        let mock = MockDelegate()
        session.delegate = mock

        let job = pendingJob(transcriptPath: transcriptPath)
        mock.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = makeNamingData(jobID: job.id)

        session.completeSpeakerNaming(jobID: job.id, result: .skipped)
        await waitUntil { mock.jobs[job.id]?.state == .done }

        XCTAssertTrue(mock.updateSpeakerDBCalls.isEmpty)
    }

    // MARK: - Why the centroid quality filter does not contain the damage

    /// The 3 s `minSpeakingTimeForCentroid` filter guards only the centroid.
    /// The recent-samples FIFO is appended unconditionally, and matching takes
    /// the *closer* of the two anchors — so a short, wrong-voice confirmation
    /// still becomes a live match anchor for subsequent meetings.
    func testShortConfirmationStillEntersSampleFIFO() throws {
        let existing = StoredSpeaker(
            name: "Alice",
            embeddings: [[1, 0, 0]],
            centroid: [1, 0, 0],
            centroidSampleCount: 1,
        )
        let wrongVoice: [Float] = [0, 1, 0]

        let updated = SpeakerMatcher.applyConfirmation(
            to: existing,
            embedding: wrongVoice,
            duration: 1.0, // below minSpeakingTimeForCentroid
            now: Date(),
        )

        XCTAssertEqual(updated.centroid, [1, 0, 0], "centroid must stay filtered")
        XCTAssertEqual(updated.centroidSampleCount, 1)
        XCTAssertTrue(
            updated.embeddings.contains(wrongVoice),
            "short confirmation still lands in the FIFO the matcher reads",
        )

        // Storage alone would be harmless — the damage is that `match` reads the
        // FIFO as a second anchor and takes whichever is closer. The centroid
        // stayed clean and is orthogonal to the query, yet the polluted sample
        // still auto-names a future wrong-voice speaker "Alice".
        let tmp = try makeTempDirectory(prefix: "AccidentalNamingAcceptTests")
        let matcher = SpeakerMatcher(dbPath: tmp.appendingPathComponent("speakers.json"))
        matcher.saveDB([updated])
        XCTAssertEqual(matcher.match(embeddings: ["S0": wrongVoice])["S0"], "Alice")
    }
}
