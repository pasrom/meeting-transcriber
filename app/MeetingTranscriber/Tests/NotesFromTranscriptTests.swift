@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Generate Meeting Notes from Transcript: notes-only jobs for transcripts the
/// user picks, through the queue, the controller, the menu and `/v1`.
@MainActor
final class NotesFromTranscriptTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = try makeTempDirectory(prefix: "notes_from_transcript")
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    // MARK: - Queue

    func testEachTranscriptGetsItsNotesWithoutTranscribing() async throws {
        let engine = MockEngine()
        let generator = MockProtocolGen()
        let queue = makeQueue(engine: engine, generator: generator)
        let first = try transcript("20261030_0900_standup")
        let second = try transcript("20261031_1400_review")

        let outcome = queue.enqueueNotes(fromTranscripts: [first, second])
        await queue.awaitProcessing()

        XCTAssertEqual(outcome.queued.count, 2)
        XCTAssertEqual(queue.jobs.map(\.state), [.done, .done])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("20261030_0900_standup.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("20261031_1400_review.md").path))
        XCTAssertEqual(engine.transcribeCallCount, 0, "a notes-only job transcribed audio")
        XCTAssertEqual(generator.capturedMeetingStartTime, PipelineQueue.meetingStart(fromStem: "20261031_1400_review"))
    }

    /// The picked file is the user's, not a run's output: the settings that
    /// delete or rename a run's raw transcript must not touch it.
    func testThePickedTranscriptIsNeitherRemovedNorRenamed() async throws {
        let generator = MockProtocolGen()
        generator.headingTitle = "Quarterly Planning"
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            outputDir: dir, logDir: dir, saveRawTranscriptSeparately: false, useAITitleForFilenames: true,
        )
        let url = try transcript("20261030_0900_standup")

        queue.enqueueNotes(fromTranscripts: [url])
        await queue.awaitProcessing()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[Me] Hello")
        XCTAssertEqual(queue.jobs.first?.protocolPath?.lastPathComponent, "20261030_0900_standup.md")
    }

    func testTranscriptsWithNotesOrNothingToReadAreLeftOut() throws {
        let queue = makeQueue()
        let withNotes = try transcript("20261030_0900_standup")
        try "# Notes".write(to: dir.appendingPathComponent("20261030_0900_standup.md"), atomically: true, encoding: .utf8)
        let empty = dir.appendingPathComponent("empty.txt")
        try " \n".write(to: empty, atomically: true, encoding: .utf8)
        let audio = dir.appendingPathComponent("call.wav")
        try Data().write(to: audio)

        let outcome = queue.enqueueNotes(fromTranscripts: [withNotes, empty, audio])

        XCTAssertEqual(outcome.queued, [])
        XCTAssertEqual(outcome.notesExist, [withNotes])
        XCTAssertEqual(outcome.unreadable, [empty, audio])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("20261030_0900_standup.md"), encoding: .utf8), "# Notes")
        XCTAssertEqual(
            outcome.skippedNotice?.body,
            "Notes already exist for 20261030_0900_standup.txt. Could not read empty.txt, call.wav.",
        )
    }

    func testNotesWrittenWhileTheJobWaitedAreNotOverwritten() async throws {
        let queue = makeQueue()
        let url = try transcript("20261030_0900_standup")
        var job = PipelineJob(meetingTitle: "standup", appName: "Transcript", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.transcriptPath = url
        job.namingSlug = "20261030_0900_standup"
        job.generatesNotesOnly = true
        queue.insertJobForTesting(job)
        let notes = dir.appendingPathComponent("20261030_0900_standup.md")
        try "# By hand".write(to: notes, atomically: true, encoding: .utf8)

        await queue.generateNotesOnly(job)

        XCTAssertEqual(queue.jobs.first?.state, .error)
        XCTAssertEqual(queue.jobs.first?.error, PipelineQueue.notesOnlyNotesExistError)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "# By hand")
    }

    func testAWaitingJobStillMakesOnlyNotesAfterARelaunch() async throws {
        let engine = MockEngine()
        let queue = makeQueue()
        var job = PipelineJob(meetingTitle: "standup", appName: "Transcript", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.transcriptPath = try transcript("20261030_0900_standup")
        job.namingSlug = "20261030_0900_standup"
        job.generatesNotesOnly = true
        queue.insertJobForTesting(job)
        queue.saveSnapshot()

        let restored = makeQueue(engine: engine)
        restored.loadSnapshot()
        restored.triggerProcessing()
        await restored.awaitProcessing()

        XCTAssertEqual(restored.jobs.first?.state, .done)
        XCTAssertEqual(engine.transcribeCallCount, 0)
    }

    func testTheStampInTheNameIsTheMeetingStart() throws {
        let start = try XCTUnwrap(PipelineQueue.meetingStart(fromStem: "20261030_0915_standup"))
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: start)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 10, 30, 9, 15])
        XCTAssertNil(PipelineQueue.meetingStart(fromStem: "standup"))
    }

    // MARK: - Controller

    func testWithoutANotesProviderNothingIsQueuedAndTheUserIsTold() throws {
        let notifier = RecordingNotifier()
        let controller = try makeController(provider: .none, notifier: notifier)

        XCTAssertNil(try controller.generateNotes(fromTranscripts: [transcript("20261030_0900_standup")]))
        XCTAssertTrue(controller.queue.jobs.isEmpty)
        XCTAssertEqual(notifier.calls.last?.title, PipelineController.notesProviderNoneNotice.title)
    }

    func testSkippedTranscriptsAreNamedInANotification() throws {
        let notifier = RecordingNotifier()
        let controller = try makeController(provider: .claudeCLI, notifier: notifier)
        let url = try transcript("20261030_0900_standup")
        try "# Notes".write(to: dir.appendingPathComponent("20261030_0900_standup.md"), atomically: true, encoding: .utf8)

        let outcome = controller.generateNotes(fromTranscripts: [url])

        XCTAssertEqual(outcome?.notesExist, [url])
        XCTAssertEqual(notifier.calls.last?.title, "Some Transcripts Were Skipped")
    }

    // MARK: - Menu

    func testTheMenuItemAsksForTranscripts() throws {
        var asked = false
        let menu = MenuBarView(
            status: nil, isWatching: false, pipelineQueue: makeQueue(),
            onStartStop: {}, onRecordApp: {}, onRecordMicrophone: {}, noMic: false,
            manualRecordingPendingOrActive: false, onStopManualRecording: nil,
            onOpenProtocol: { _ in }, onOpenProtocolsFolder: {}, onOpenSettings: {},
            onNameSpeakers: nil, onProcessFiles: {}, onDismissJob: { _ in }, onQuit: {},
            onGenerateNotesFromTranscripts: { asked = true },
        )
        try menu.inspect().find(viewWithAccessibilityIdentifier: A11yID.generateNotesFromTranscriptButton).button().tap()
        XCTAssertTrue(asked)
    }

    // MARK: - /v1

    #if !APPSTORE
        func testV1GenerateAnswersWithWhatWasQueuedAndLeftOut() async throws {
            let queue = makeQueue()
            let url = try transcript("20261030_0900_standup")
            var actions = MeetingNotesActions()
            actions.generate = { queue.enqueueNotes(fromTranscripts: $0) }
            let server = DebugRPCServer(port: 0, token: "t", snapshot: { .empty }, meetingNotes: actions)
            func post(_ body: String) async -> HTTPResponse {
                await server.route(HTTPRequest(
                    method: "POST", path: "/v1/jobs/notes/generate",
                    headers: ["authorization": "Bearer t"], body: Data(body.utf8),
                ))
            }

            let generated = await post(#"{"paths":["\#(url.path)","/nonexistent/x.txt"]}"#)
            XCTAssertEqual(generated.status, 200)
            let response = try JSONDecoder().decode(NotesFromTranscriptResponse.self, from: generated.body)
            XCTAssertEqual(response.jobIDs, queue.jobs.map(\.id.uuidString))
            XCTAssertEqual(response.unreadable, ["/nonexistent/x.txt"])
            let empty = await post(#"{"paths":[]}"#)
            XCTAssertEqual(empty.status, 400)

            let refusing = DebugRPCServer(port: 0, token: "t") { .empty }
            let refused = await refusing.route(HTTPRequest(
                method: "POST", path: "/v1/jobs/notes/generate",
                headers: ["authorization": "Bearer t"], body: Data(#"{"paths":["\#(url.path)"]}"#.utf8),
            ))
            XCTAssertEqual(refused.status, 409, "no notes provider: nothing can be queued")
        }

        /// `AppState.buildDebugRPCServer` hands the server the controller's
        /// generate, not the refusing default. A transcript that already has
        /// notes keeps the test from running a generator.
        func testTheAppWiresTheV1GenerateToItsController() async throws {
            let url = try transcript("20261030_0900_standup")
            try "# Notes".write(to: dir.appendingPathComponent("20261030_0900_standup.md"), atomically: true, encoding: .utf8)
            let state = try AppState(
                pipelineEnvironment: IsolatedQueueEnvironment.make(logDir: dir, initialQueue: makeQueue()),
                settings: makeSettings(provider: .claudeCLI),
                notifier: SilentNotifier(),
            )

            let response = await state.buildDebugRPCServer(token: "t").route(HTTPRequest(
                method: "POST", path: "/v1/jobs/notes/generate",
                headers: ["authorization": "Bearer t"], body: Data(#"{"paths":["\#(url.path)"]}"#.utf8),
            ))

            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try JSONDecoder().decode(NotesFromTranscriptResponse.self, from: response.body).notesExist, [url.path])
        }
    #endif

    // MARK: - Fixtures

    private func makeQueue(engine: MockEngine = MockEngine(), generator: MockProtocolGen = MockProtocolGen()) -> PipelineQueue {
        PipelineQueue(
            engine: engine, diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            outputDir: dir, logDir: dir,
        )
    }

    private func transcript(_ stem: String) throws -> URL {
        let url = dir.appendingPathComponent("\(stem).txt")
        try "[Me] Hello".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeSettings(provider: ProtocolProvider) throws -> AppSettings {
        let suite = "notes-from-transcript-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(defaults: XCTUnwrap(DefaultsSuite.open(suite)))
        settings.protocolProvider = provider
        return settings
    }

    /// A controller whose queue runs mocks, so nothing it queues reaches a
    /// real provider.
    private func makeController(provider: ProtocolProvider, notifier: RecordingNotifier) throws -> PipelineController {
        try PipelineController(
            settings: makeSettings(provider: provider),
            notifier: notifier,
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: dir, initialQueue: makeQueue()),
        )
    }
}
