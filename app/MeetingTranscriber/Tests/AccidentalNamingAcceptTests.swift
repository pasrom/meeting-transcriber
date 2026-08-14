@testable import MeetingTranscriber
import SwiftUI
import ViewInspector
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
        private(set) var warnings: [String] = []
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

        func addWarning(id _: UUID, _ message: String) {
            warnings.append(message)
        }

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
        /// protocol factory that turned nil after the probe). Both are handled
        /// by the session rather than here — see the missing-transcript test.
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
            echoVerdict: nil,
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

    /// Stale cleanup commits the auto-names for a job nobody ever decided, so it
    /// logs like any other resolution — tagged `.stale`, which is what tells it
    /// apart from a person clicking Skip. It used to write nothing at all,
    /// leaving that outcome invisible.
    func testStaleCleanupWritesStaleTaggedRow() async throws {
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
        var rows = await statsLog.loadRecent(within: 3600)
        let deadline = Date().addingTimeInterval(2)
        while rows.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
            rows = await statsLog.loadRecent(within: 3600)
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.action, .dismissed)
        XCTAssertEqual(rows.first?.source, .stale)
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

        session.completeSpeakerNaming(jobID: job.id, result: .skipped, source: .dialog)

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
        XCTAssertEqual(rows.first?.source, .dialog, "a click in the dialog is attributable")
    }

    /// `acceptAutoNames` destroys the naming data before the protocol task is
    /// guaranteed to transition the job, and its readiness probe only checks
    /// that `transcriptPath` is non-nil — not that the file is still there. So
    /// the generation task can bail on an unreadable transcript after the
    /// sidecars are already gone. Every exit of that task must therefore be
    /// terminal: a job left in `.speakerNamingPending` with no naming data
    /// reopens the dialog on an empty placeholder and is dropped without a
    /// protocol at the next launch.
    func testSkipWithMissingTranscriptStillFinishesTheJob() async throws {
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

        session.completeSpeakerNaming(jobID: job.id, result: .skipped, source: .dialog)

        await waitUntil { mock.jobs[job.id]?.state == .done }

        XCTAssertEqual(
            mock.jobs[job.id]?.state, .done,
            "an unreadable transcript must still resolve the job, not strand it",
        )
        XCTAssertNil(session.speakerNamingDataByJob[job.id], "naming data is gone")
        XCTAssertEqual(mock.generateProtocolCallCount, 0, "no protocol could be produced")
        XCTAssertEqual(mock.warnings.count, 1, "the user is told why there is no protocol")
    }

    // MARK: - Escape dismisses, never resolves

    /// The load-bearing guarantee of the fix: the Escape handler runs the host's
    /// dismiss action and never resolves the job. Skip used to be bound to
    /// Escape, so this is the regression that must stay red if anyone rebinds
    /// it.
    func testExitCommandDismissesWithoutResolvingTheJob() throws {
        var dismissed = 0
        var results: [PipelineQueue.SpeakerNamingResult] = []
        let view = SpeakerNamingView(
            data: makeNamingData(jobID: UUID()),
            gracePeriod: 0,
            onDismissRequest: { dismissed += 1 },
            onComplete: { results.append($0) },
        )

        try view.inspect().vStack().callOnExitCommand()

        XCTAssertEqual(dismissed, 1)
        XCTAssertTrue(results.isEmpty, "Escape must never resolve the job")
    }

    /// A host with no window to close installs no handler at all, so Escape
    /// keeps bubbling. Voice enrollment renders this view inside a sheet, where
    /// swallowing Escape would break sheet-dismisses-on-Escape for exactly one
    /// stage of the flow.
    func testExitCommandIsNotInstalledWithoutADismissHandler() throws {
        let view = SpeakerNamingView(
            data: makeNamingData(jobID: UUID()),
            gracePeriod: 0,
        ) { _ in }

        XCTAssertThrowsError(try view.inspect().vStack().callOnExitCommand())
    }

    // MARK: - Headless resolution

    /// Blocking-transcribe finishes on the auto-names with no dialog. The names
    /// still reach the transcript, so the decision is logged like any other —
    /// tagged `.headless`. It used to write no row, hiding an auto-accept that
    /// nobody reviewed.
    func testHeadlessAutoSkipWritesHeadlessTaggedRow() async throws {
        let tmp = try makeTempDirectory(prefix: "AccidentalNamingAcceptTests")
        let logPath = tmp.appendingPathComponent("recognition_log.jsonl")
        let statsLog = RecognitionStatsLog(path: logPath)

        let session = makeSession(outputDir: tmp, statsLog: statsLog)
        let mock = MockDelegate()
        session.delegate = mock

        var job = PipelineJob(
            meetingTitle: "Standup", appName: "Test",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
            autoSkipNaming: true,
        )
        job.state = .diarizing
        mock.jobs[job.id] = job

        let diarization = DiarizationResult(
            segments: [.init(start: 0, end: 12, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 12],
            autoNames: ["SPEAKER_0": "SPEAKER_0"],
            embeddings: ["SPEAKER_0": [0.1, 0.2, 0.3]],
        )
        _ = session.resolveSpeakerNames(
            diarization: diarization,
            job: (jobID: job.id, title: "Standup", slug: "standup_abcd1234", participants: []),
            diarizeProcess: MockDiarization(),
            isDualSource: false, outputDir: tmp,
        )

        // No dialog is parked for a headless job.
        XCTAssertNil(session.speakerNamingDataByJob[job.id])

        var rows = await statsLog.loadRecent(within: 3600)
        let deadline = Date().addingTimeInterval(2)
        while rows.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
            rows = await statsLog.loadRecent(within: 3600)
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.source, .headless)
    }

    // MARK: - Log schema stays backward compatible

    /// Rows written before `source` existed must still decode, and must read as
    /// `nil` rather than being attributed to a source they never recorded.
    /// `RecognitionStatsLog.loadRecent` drops lines it cannot decode, so a
    /// non-optional field here would silently erase the entire history.
    func testLegacyLogLineWithoutSourceStillDecodes() throws {
        let legacy = """
        {"action":"accepted","autoName":"Alice","jobID":"\(UUID().uuidString)",\
        "label":"SPEAKER_0","meetingTitle":"Standup","track":"single",\
        "ts":"2026-01-01T00:00:00Z","userName":"Alice"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(RecognitionEvent.self, from: Data(legacy.utf8))

        XCTAssertEqual(event.action, .accepted)
        XCTAssertNil(event.source)
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
        session.completeSpeakerNaming(jobID: job.id, result: .confirmed(["SPEAKER_0": "Alice"]), source: .dialog)

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

        session.completeSpeakerNaming(jobID: job.id, result: .skipped, source: .dialog)
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
