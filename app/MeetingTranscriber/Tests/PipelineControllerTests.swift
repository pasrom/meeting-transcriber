@testable import MeetingTranscriber
import XCTest

/// Unit tests for `PipelineController`'s queue lifecycle — exercised on a bare
/// controller (no full `AppState`), which is the construction the extraction
/// enables. They focus on the genuinely-new `engineProvider` seam: before the
/// split, `makePipelineQueue` read `AppState.activeTranscriptionEngine`
/// directly, so the "no engine source wired" path and the provider→engine
/// wiring couldn't be exercised in isolation.
@MainActor
final class PipelineControllerTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// A controller whose queue is already wired to a mock engine + isolated
    /// `logDir`, so `ensureQueue()` short-circuits and no production-path I/O
    /// is touched.
    private func makeWiredController() -> PipelineController {
        let pc = PipelineController(settings: AppSettings(), notifier: RecordingNotifier())
        pc.queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: tmpDir,
            logDir: tmpDir,
        )
        return pc
    }

    // MARK: - engineProvider seam

    func testMakeQueueReturnsCurrentQueueWhenProviderUnset() {
        let pc = PipelineController(settings: AppSettings(), notifier: RecordingNotifier())
        pc.queue = PipelineQueue(logDir: tmpDir)
        let before = pc.queue

        // No `activate(engineProvider:)` call → the defensive guard returns the
        // current queue instead of building one without an engine.
        let result = pc.makeQueue()

        XCTAssertIdentical(result, before, "makeQueue must return the current queue when no engine provider is wired")
    }

    func testEnsureQueueRebuildsBareQueueUsingProviderEngine() {
        let pc = PipelineController(settings: AppSettings(), notifier: RecordingNotifier())
        pc.queue = PipelineQueue(logDir: tmpDir)
        XCTAssertNil(pc.queue.engine, "Precondition: fresh queue has no engine")

        let engine = MockEngine()
        pc.activate { engine }
        pc.ensureQueue()

        XCTAssertIdentical(
            pc.queue.engine as AnyObject, engine,
            "ensureQueue must rebuild the bare queue with the engine the provider supplies",
        )
    }

    func testEnsureQueueIsNoOpWhenEngineAlreadySet() {
        let pc = makeWiredController()
        let before = ObjectIdentifier(pc.queue)

        pc.ensureQueue()

        XCTAssertEqual(
            ObjectIdentifier(pc.queue), before,
            "ensureQueue must not replace a queue that is already wired to an engine",
        )
    }

    // MARK: - enqueueFiles (bare controller)

    func testEnqueueFilesCreatesJobOnBareController() {
        let pc = makeWiredController()

        pc.enqueueFiles([URL(fileURLWithPath: "/tmp/sprint-review.wav")])

        XCTAssertEqual(pc.queue.jobs.count, 1)
        XCTAssertEqual(pc.queue.jobs[0].meetingTitle, "sprint-review")
    }

    func testEnqueueFilesReturnsCreatedJobIDs() {
        let pc = makeWiredController()

        let ids = pc.enqueueFiles([URL(fileURLWithPath: "/tmp/sprint-review.wav")])

        XCTAssertEqual(ids, pc.queue.jobs.map(\.id), "Returned IDs must match the enqueued jobs")
    }

    func testEnqueueExistingFilesReturningIDsFiltersMissingFiles() {
        let pc = makeWiredController()
        let existing = tmpDir.appendingPathComponent("real-meeting.wav")
        FileManager.default.createFile(atPath: existing.path, contents: Data("RIFF".utf8))
        let missing = URL(fileURLWithPath: "/tmp/no-such-file-\(UUID().uuidString).wav")

        let ids = pc.enqueueExistingFilesReturningIDs([existing, missing])

        XCTAssertEqual(ids.count, 1, "Only the file that exists on disk is enqueued")
        XCTAssertEqual(ids, pc.queue.jobs.map(\.id))
    }

    func testEnqueueExistingFilesCountsExistingFilesNotCollapsedJobs() {
        let pc = makeWiredController()
        // A paired _app + _mic recording collapses into ONE job, but the
        // documented `enqueued` count is the number of files that existed.
        let app = tmpDir.appendingPathComponent("standup_app.wav")
        let mic = tmpDir.appendingPathComponent("standup_mic.wav")
        FileManager.default.createFile(atPath: app.path, contents: Data("RIFF".utf8))
        FileManager.default.createFile(atPath: mic.path, contents: Data("RIFF".utf8))

        let count = pc.enqueueExistingFiles([app, mic])

        XCTAssertEqual(count, 2, "Count reflects files that existed on disk, not collapsed jobs")
        XCTAssertEqual(pc.queue.jobs.count, 1, "Paired _app + _mic collapse into a single job")
    }

    // MARK: - jobStatus

    func testJobStatusReturnsLiveJob() {
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let pc = PipelineController(settings: AppSettings(), notifier: RecordingNotifier(), terminalJobStore: store)
        pc.queue = PipelineQueue(logDir: tmpDir)
        var job = PipelineJob(
            meetingTitle: "Live Sync", appName: "File",
            mixPath: URL(fileURLWithPath: "/tmp/x.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        job.transcriptPath = URL(fileURLWithPath: "/out/x.txt")
        pc.queue.insertJobForTesting(job)

        let dto = pc.jobStatus(forID: job.id)

        XCTAssertEqual(dto?.state, .waiting)
        XCTAssertEqual(dto?.meetingTitle, "Live Sync")
        XCTAssertEqual(dto?.transcriptPath, "/out/x.txt")
    }

    func testJobStatusFallsBackToTerminalStore() {
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let pc = PipelineController(settings: AppSettings(), notifier: RecordingNotifier(), terminalJobStore: store)
        let id = UUID()
        store.record(JobStatusDTO(
            jobID: id.uuidString, state: .done, meetingTitle: "Reaped",
            transcriptPath: "/out/r.txt", protocolPath: nil, error: nil, warnings: [],
        ))

        let dto = pc.jobStatus(forID: id)

        XCTAssertEqual(dto?.state, .done, "Must read back a job already reaped from the queue")
        XCTAssertEqual(dto?.meetingTitle, "Reaped")
        XCTAssertEqual(dto?.transcriptPath, "/out/r.txt")
    }

    func testJobStatusUnknownReturnsNil() {
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let pc = PipelineController(settings: AppSettings(), notifier: RecordingNotifier(), terminalJobStore: store)
        XCTAssertNil(pc.jobStatus(forID: UUID()))
    }

    // MARK: - namingStatus / confirmNaming / skipNaming

    /// Seed a pending-speaker-naming job on the controller's queue, return its id.
    private func seedPendingNaming(
        on pc: PipelineController,
        mapping: [String: String],
        speakingTimes: [String: TimeInterval] = [:],
        participants: [String] = [],
    ) -> UUID {
        let job = PipelineJob(
            meetingTitle: "Q3 Sync", appName: "File",
            mixPath: URL(fileURLWithPath: "/tmp/x.wav"), appPath: nil, micPath: nil, micDelay: 0,
        )
        pc.queue.insertJobForTesting(job)
        pc.queue.speakerNamingDataByJob[job.id] = PipelineQueue.SpeakerNamingData(
            jobID: job.id, meetingTitle: "Q3 Sync",
            mapping: mapping, speakingTimes: speakingTimes,
            embeddings: [:], audioPath: nil, segments: [], participants: participants,
            isDualSource: false,
        )
        pc.queue.updateJobState(id: job.id, to: .speakerNamingPending)
        return job.id
    }

    func testNamingStatusMapsPendingNamingData() {
        let pc = makeWiredController()
        let id = seedPendingNaming(
            on: pc,
            mapping: ["Speaker 1": "Roman", "Speaker 2": "Speaker 2"],
            speakingTimes: ["Speaker 1": 42, "Speaker 2": 7],
            participants: ["Alice"],
        )

        let dto = pc.namingStatus(forID: id)

        XCTAssertEqual(dto?.meetingTitle, "Q3 Sync")
        XCTAssertEqual(dto?.participants, ["Alice"])
        XCTAssertEqual(dto?.speakers.map(\.label), ["Speaker 1", "Speaker 2"], "speakers sorted by label")
        XCTAssertEqual(dto?.speakers.first?.suggested, "Roman")
        XCTAssertEqual(dto?.speakers.first?.speakingSeconds, 42)
    }

    func testNamingStatusUnknownReturnsNil() {
        XCTAssertNil(makeWiredController().namingStatus(forID: UUID()))
    }

    func testConfirmNamingResolvesPendingJobAndRejectsUnknown() {
        let pc = makeWiredController()
        let id = seedPendingNaming(on: pc, mapping: ["Speaker 1": "Speaker 1"])

        XCTAssertTrue(pc.confirmNaming(jobID: id, mapping: ["Speaker 1": "Roman"]))
        XCTAssertFalse(pc.confirmNaming(jobID: UUID(), mapping: [:]), "no pending naming → false")
    }

    func testConfirmNamingIsIdempotentOnRetry() {
        let pc = makeWiredController()
        let id = seedPendingNaming(on: pc, mapping: ["Speaker 1": "Speaker 1"])

        XCTAssertTrue(pc.confirmNaming(jobID: id, mapping: ["Speaker 1": "Roman"]))
        // Confirming transitions the job out of .speakerNamingPending, so a
        // duplicate call (automation retry) is rejected — no double-processing.
        XCTAssertFalse(pc.confirmNaming(jobID: id, mapping: ["Speaker 1": "Roman"]), "retry rejected")
    }

    func testSkipNamingResolvesPendingJobAndRejectsUnknown() {
        let pc = makeWiredController()
        let id = seedPendingNaming(on: pc, mapping: ["Speaker 1": "Speaker 1"])

        XCTAssertTrue(pc.skipNaming(jobID: id))
        XCTAssertFalse(pc.skipNaming(jobID: UUID()), "no pending naming → false")
    }

    // MARK: - transcribeAndWait (blocking)

    func testTranscribeAndWaitReturnsNoFileForMissingPath() async {
        let pc = makeWiredController()
        let result = await pc.transcribeAndWait(
            path: URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString).wav"), maxWaitSeconds: 1,
        )
        guard case .noFile = result else { XCTFail("expected .noFile, got \(result)"); return }
    }

    func testTranscribeAndWaitCompletesJob() async {
        let pc = makeWiredController()
        let file = tmpDir.appendingPathComponent("blocking.wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("RIFF".utf8))

        let result = await pc.transcribeAndWait(path: file, maxWaitSeconds: 10, pollInterval: .milliseconds(10))

        guard case let .completed(dto) = result else { XCTFail("expected .completed, got \(result)"); return }
        XCTAssertTrue(dto.state == .done || dto.state == .error, "wait loop returns on terminal state: \(dto.state)")
    }

    func testTranscribeAndWaitTimesOutWhileInFlight() async {
        let pc = makeWiredController()
        let file = tmpDir.appendingPathComponent("blocking-timeout.wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("RIFF".utf8))

        // maxWaitSeconds 0 → the deadline is already past, so the just-enqueued
        // (still non-terminal) job yields a timeout with its in-flight status.
        let result = await pc.transcribeAndWait(path: file, maxWaitSeconds: 0, pollInterval: .milliseconds(10))

        guard case let .timedOut(dto) = result else { XCTFail("expected .timedOut, got \(result)"); return }
        XCTAssertNotEqual(dto?.state, .done)
    }

    func testTranscribeAndWaitFallsBackToTerminalStoreWhenJobReaped() async {
        // A job that completed and was reaped from the live queue before the poll
        // loop observed it must still resolve via the terminal store (the slow
        // poller the store exists for). ReapingQueue reproduces that
        // deterministically: enqueue records a terminal DTO and leaves `jobs`
        // empty.
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_reap.json"))
        let pc = PipelineController(settings: AppSettings(), notifier: RecordingNotifier(), terminalJobStore: store)
        pc.queue = ReapingQueue(store: store)

        let file = tmpDir.appendingPathComponent("reaped.wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("RIFF".utf8))

        let result = await pc.transcribeAndWait(path: file, maxWaitSeconds: 5, pollInterval: .milliseconds(10))

        guard case let .completed(dto) = result else { XCTFail("expected .completed from terminal store, got \(result)"); return }
        XCTAssertEqual(dto.state, .done)
    }
}

/// A `PipelineQueue` whose `enqueue` records a terminal DTO to the store and
/// never keeps the job in `jobs` — reproduces a job reaped from the live queue
/// before `transcribeAndWait`'s poll loop observes it.
@MainActor
private final class ReapingQueue: PipelineQueue {
    private let store: TerminalJobStore

    init(store: TerminalJobStore) {
        self.store = store
        super.init(terminalJobStore: store)
    }

    override func enqueue(_ job: PipelineJob) {
        store.record(JobStatusDTO(
            jobID: job.id.uuidString, state: .done, meetingTitle: job.meetingTitle,
            transcriptPath: nil, protocolPath: nil, error: nil, warnings: [],
        ))
    }
}
