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
}
