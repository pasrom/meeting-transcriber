@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Retrying meeting notes that could not be generated: the job that keeps
/// them on offer, the retry from the saved transcript, the menu rows and the
/// `/v1` routes.
@MainActor
final class MeetingNotesRetryTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = try makeTempDirectory(prefix: "notes_retry")
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    // MARK: - Held after completion

    func testFailedNotesKeepTheJobListedPastItsLifetime() async throws {
        let queue = makeQueue(lifetime: 0)
        let id = try insertFailedNotesJob(into: queue)
        queue.scheduleCompletedJobRemoval(id: id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(queue.canRetryMeetingNotes(id: id), "the job left the list before its notes were retried")
    }

    func testFailedNotesSurviveARelaunch() throws {
        let queue = makeQueue()
        let id = try insertFailedNotesJob(into: queue)
        queue.saveSnapshot()

        let restored = makeQueue()
        restored.loadSnapshot()
        XCTAssertTrue(restored.canRetryMeetingNotes(id: id), "the restore dropped a job whose notes failed")
    }

    // MARK: - Retry

    func testRetryMakesTheNotesFromTheSavedTranscript() async throws {
        let generator = MockProtocolGen()
        let engine = MockEngine()
        let queue = makeQueue(engine: engine, generator: generator)
        let id = try insertFailedNotesJob(into: queue)

        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()

        let job = try XCTUnwrap(queue.jobs.first { $0.id == id })
        XCTAssertEqual(job.state, .done)
        XCTAssertNil(job.protocolFailure)
        XCTAssertFalse(job.warnings.contains(PipelineQueue.protocolGenerationFailedWarning))
        XCTAssertEqual(job.protocolPath?.lastPathComponent, "20261030_0900_sprint.md")
        XCTAssertEqual(generator.capturedTranscript, "[Me] Hello")
        XCTAssertEqual(engine.transcribeCallCount, 0, "the retry transcribed the meeting again")
    }

    func testRetryNeverOverwritesExistingNotes() throws {
        let queue = makeQueue()
        let id = try insertFailedNotesJob(into: queue)
        let notes = dir.appendingPathComponent("20261030_0900_sprint.md")
        try "# Written by hand".write(to: notes, atomically: true, encoding: .utf8)

        XCTAssertFalse(queue.retryMeetingNotes(id: id))

        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "# Written by hand")
        XCTAssertFalse(queue.canRetryMeetingNotes(id: id), "the retry is still offered for notes that exist")
        XCTAssertTrue(queue.jobs.first { $0.id == id }?.warnings.contains(PipelineQueue.notesRetryNotesExistWarning) ?? false)
    }

    func testAMissingTranscriptKeepsTheRetryOnOffer() throws {
        let queue = makeQueue()
        let id = try insertFailedNotesJob(into: queue)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("20261030_0900_sprint.txt"))

        XCTAssertFalse(queue.retryMeetingNotes(id: id))

        let job = try XCTUnwrap(queue.jobs.first { $0.id == id })
        XCTAssertEqual(job.state, .done, "a notes retry turned into a full run")
        XCTAssertTrue(job.warnings.contains(PipelineQueue.notesRetryTranscriptMissingWarning))
        XCTAssertTrue(queue.canRetryMeetingNotes(id: id), "a volume that comes back should be retryable again")
    }

    func testRetryAllQueuesEveryFailedNotesJob() async throws {
        let queue = makeQueue()
        let first = try insertFailedNotesJob(into: queue, stem: "20261030_0900_sprint")
        let second = try insertFailedNotesJob(into: queue, stem: "20261031_1000_review")

        XCTAssertEqual(queue.retryAllMeetingNotes(), [first, second])
        await queue.awaitProcessing()

        XCTAssertTrue(queue.jobsWithRetryableMeetingNotes.isEmpty)
        XCTAssertNotNil(queue.jobs.first { $0.id == second }?.protocolPath)
    }

    // MARK: - Menu

    func testTheRetryRowRetriesTheJobOfItsOwnRow() throws {
        let queue = makeQueue()
        let first = try insertFailedNotesJob(into: queue, stem: "20261030_0900_sprint")
        let second = try insertFailedNotesJob(into: queue, stem: "20261031_1000_review")

        try makeMenu(queue).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.jobNotesRetryButton(1)).button().tap()

        XCTAssertEqual(queue.jobs.first { $0.id == second }?.state, .waiting)
        XCTAssertEqual(queue.jobs.first { $0.id == first }?.state, .done)
    }

    func testRetryAllIsOfferedFromTwoFailedJobs() throws {
        let queue = makeQueue()
        try insertFailedNotesJob(into: queue, stem: "20261030_0900_sprint")
        XCTAssertThrowsError(
            try makeMenu(queue).inspect().find(viewWithAccessibilityIdentifier: A11yID.retryAllMeetingNotesButton),
            "one failed job has its own row; Retry All only repeats it",
        )

        try insertFailedNotesJob(into: queue, stem: "20261031_1000_review")
        let button = try makeMenu(queue).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.retryAllMeetingNotesButton).button()
        XCTAssertEqual(try button.labelView().text().string(), "Retry All Meeting Notes (2)")
        try button.tap()
        XCTAssertEqual(queue.jobs.map(\.state), [.waiting, .waiting])
    }

    // MARK: - /v1

    #if !APPSTORE
        func testV1RetryAnswersByWhatTheQueueDid() async throws {
            let queue = makeQueue()
            let id = try insertFailedNotesJob(into: queue)
            let server = DebugRPCServer(
                port: 0, token: "t", snapshot: { .empty },
                jobStatus: { id in queue.jobs.first { $0.id == id }.map { JobStatusDTO(job: $0) } },
                meetingNotes: MeetingNotesActions(
                    retry: { queue.retryMeetingNotes(id: $0) },
                    retryAll: { queue.retryAllMeetingNotes() },
                ),
            )
            func post(_ path: String) async -> HTTPResponse {
                await server.route(HTTPRequest(method: "POST", path: path, headers: ["authorization": "Bearer t"]))
            }

            let retried = await post("/v1/jobs/\(id.uuidString)/notes/retry")
            XCTAssertEqual(retried.status, 200)
            XCTAssertEqual(try JSONDecoder().decode(JobStatusDTO.self, from: retried.body).jobID, id.uuidString)
            let again = await post("/v1/jobs/\(id.uuidString)/notes/retry")
            XCTAssertEqual(again.status, 409, "a job already queued again has nothing to retry")
            let unknown = await post("/v1/jobs/\(UUID().uuidString)/notes/retry")
            XCTAssertEqual(unknown.status, 404)
            let all = await post("/v1/jobs/notes/retry")
            XCTAssertEqual(all.status, 200)
            XCTAssertEqual(String(data: all.body, encoding: .utf8), #"{"jobIDs":[]}"#)
        }

        /// `AppState.buildDebugRPCServer` hands the server the queue's retry,
        /// not the refusing defaults.
        func testTheAppWiresTheV1RetryToItsQueue() async throws {
            let queue = makeQueue()
            let id = try insertFailedNotesJob(into: queue)
            let suite = "notes-retry-\(UUID().uuidString)"
            addTeardownBlock { DefaultsSuite.remove(suite) }
            let state = try AppState(
                pipelineEnvironment: IsolatedQueueEnvironment.make(logDir: dir, initialQueue: queue),
                settings: AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite))),
                notifier: SilentNotifier(),
            )
            let server = state.buildDebugRPCServer(token: "t")

            let response = await server.route(HTTPRequest(
                method: "POST", path: "/v1/jobs/\(id.uuidString)/notes/retry", headers: ["authorization": "Bearer t"],
            ))

            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(queue.jobs.first?.state, .waiting)
        }
    #endif

    // MARK: - Fixtures

    private func makeQueue(
        lifetime: TimeInterval = 60, engine: MockEngine = MockEngine(), generator: MockProtocolGen = MockProtocolGen(),
    ) -> PipelineQueue {
        PipelineQueue(
            engine: engine, diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            outputDir: dir, logDir: dir, completedJobLifetime: lifetime,
        )
    }

    /// A job as `generateProtocol` leaves one whose provider failed: done,
    /// with its transcript saved under the meeting's stem and the failure on it.
    @discardableResult
    private func insertFailedNotesJob(into queue: PipelineQueue, stem: String = "20261030_0900_sprint") throws -> UUID {
        let transcript = dir.appendingPathComponent("\(stem).txt")
        try "[Me] Hello".write(to: transcript, atomically: true, encoding: .utf8)
        var job = PipelineJob(meetingTitle: "Sprint", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done
        job.namingSlug = stem
        job.transcriptPath = transcript
        job.warnings = [PipelineQueue.protocolGenerationFailedWarning]
        job.protocolFailure = "Claude CLI exited with code 1: Not logged in"
        queue.insertJobForTesting(job)
        return job.id
    }

    private func makeMenu(_ queue: PipelineQueue) -> MenuBarView {
        MenuBarView(
            status: nil, isWatching: false, pipelineQueue: queue,
            onStartStop: {}, onRecordApp: {}, onRecordMicrophone: {}, noMic: false,
            manualRecordingPendingOrActive: false, onStopManualRecording: nil,
            onOpenProtocol: { _ in }, onOpenProtocolsFolder: {}, onOpenSettings: {},
            onNameSpeakers: nil, onProcessFiles: {}, onDismissJob: { _ in }, onQuit: {},
        )
    }
}
