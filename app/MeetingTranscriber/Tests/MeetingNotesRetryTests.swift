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
        XCTAssertNil(job.notesFailure)
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

    // MARK: - Review scenarios

    /// A retry still waiting at a quit makes only notes after the relaunch:
    /// the recording is there, and nothing transcribes it again or replaces
    /// the transcript.
    func testAWaitingRetryStillMakesOnlyNotesAfterARelaunch() async throws {
        let first = makeQueue(generator: throwingGenerator())
        let id = try insertFailedNotesJob(into: first, withAudio: true)
        XCTAssertTrue(first.retryMeetingNotes(id: id))
        let restored = relaunch(from: first, keeping: id)

        restored.triggerProcessing()
        await restored.awaitProcessing()

        let job = try XCTUnwrap(restored.jobs.first { $0.id == id })
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.protocolPath?.lastPathComponent, "20261030_0900_sprint.md")
        XCTAssertEqual(restoredEngine.transcribeCallCount, 0, "the retry became a full run after the relaunch")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("20261030_0900_sprint.txt"), encoding: .utf8), "[Me] Hello")
    }

    /// The same without the recording: the job is not dropped for it.
    func testAWaitingRetryWithoutItsRecordingSurvivesARelaunch() async throws {
        let first = makeQueue(generator: throwingGenerator())
        let id = try insertFailedNotesJob(into: first, withAudio: true)
        XCTAssertTrue(first.retryMeetingNotes(id: id))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("20261030_0900_sprint_mix.wav"))
        let restored = relaunch(from: first, keeping: id)

        restored.triggerProcessing()
        await restored.awaitProcessing()

        XCTAssertNotNil(restored.jobs.first { $0.id == id }?.protocolPath, "the restore dropped the waiting retry")
    }

    func testASecondFailureKeepsTheRetryOnOffer() async throws {
        let queue = makeQueue(generator: throwingGenerator())
        let id = try insertFailedNotesJob(into: queue)

        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.first?.notesFailure, .other)
        XCTAssertTrue(queue.canRetryMeetingNotes(id: id))
    }

    func testNoRetryWhileTheProviderIsNone() throws {
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { nil },
            outputDir: dir, logDir: dir,
        )
        let id = try insertFailedNotesJob(into: queue)

        XCTAssertFalse(queue.retryMeetingNotes(id: id))

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.notesFailure, .claudeSignedOut, "the failure went with nothing saved")
        XCTAssertTrue(job.warnings.contains(PipelineQueue.notesRetryNoProviderWarning))
    }

    /// The provider switched to None while the retry waited: no notes, so a
    /// failure stays, now naming the missing provider, and the retry is still
    /// on offer. The transcript does not stand in for the notes either, so
    /// retention does not take the recording as done with.
    func testTheFailureStaysUntilTheNotesAreSaved() async throws {
        var providerOn = true
        let generator = MockProtocolGen()
        let registry = RecordingRetentionRegistry(path: dir.appendingPathComponent(RecordingRetentionRegistry.filename))
        let retention = RecordingRetention(registry: registry) { RecordingRetentionSettings(enabled: true, days: 0) }
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { providerOn ? generator : nil }, outputDir: dir, logDir: dir,
            recordingRetention: retention,
        )
        let id = try insertFailedNotesJob(into: queue, withAudio: true)
        registry.register(
            jobID: id, paths: [dir.appendingPathComponent("20261030_0900_sprint_mix.wav")], root: dir, recordedAt: Date(),
        )
        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        providerOn = false

        await queue.awaitProcessing()

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.notesFailure, .noProvider)
        XCTAssertTrue(job.warnings.contains(PipelineQueue.protocolGenerationFailedWarning))
        XCTAssertTrue(job.warnings.contains(PipelineQueue.notesRetryNoProviderWarning))
        XCTAssertTrue(queue.canRetryMeetingNotes(id: id))
        XCTAssertNil(registry.entries.first?.eligibleAt, "the transcript was taken for the notes the retry owes")
    }

    /// A notes retry holds no audio, so another run of the same recording
    /// (a second queue) does not refuse it.
    func testANotesRetryDoesNotClaimTheAudio() async throws {
        let runs = InFlightRunRegistry()
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir, logDir: dir, inFlightRuns: runs,
        )
        let id = try insertFailedNotesJob(into: queue, withAudio: true)
        _ = runs.begin(jobID: UUID(), mixPath: dir.appendingPathComponent("20261030_0900_sprint_mix.wav"))

        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.first?.state, .done, queue.jobs.first?.error ?? "")
        XCTAssertNotNil(queue.jobs.first?.protocolPath)
    }

    /// The transcript gone by the time the retry runs: that is the reason the
    /// job and its notification give, not the earlier one.
    func testAnUnreadableTranscriptAtRunTimeIsTheReasonGiven() async throws {
        let queue = makeQueue()
        let id = try insertFailedNotesJob(into: queue)
        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("20261030_0900_sprint.txt"))

        await queue.awaitProcessing()

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.notesFailure, .transcriptUnreadable)
        XCTAssertTrue(queue.canRetryMeetingNotes(id: id))
        XCTAssertEqual(
            PipelineQueue.doneNotification(for: job, announceNotesFailure: true).body,
            "\"Sprint\": The saved transcript could not be read.",
        )
    }

    /// Notes that appeared during the call: generated, not written, and the
    /// notification does not claim a saved transcript.
    func testNotesThatAppearDuringTheCallAreReportedAsNotWritten() async throws {
        let generator = MockProtocolGen()
        let notes = dir.appendingPathComponent("20261030_0900_sprint.md")
        generator.onGenerate = { try? "# By hand".write(to: notes, atomically: true, encoding: .utf8) }
        let queue = makeQueue(generator: generator)
        let id = try insertFailedNotesJob(into: queue)

        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertTrue(job.warnings.contains(PipelineQueue.notesWrittenMeanwhileWarning))
        XCTAssertEqual(PipelineQueue.doneNotification(for: job, announceNotesFailure: true).title, "Meeting Notes Not Saved")
    }

    /// Notes written while the model ran are not replaced.
    func testNotesWrittenDuringTheModelCallAreNotOverwritten() async throws {
        let generator = MockProtocolGen()
        let notes = dir.appendingPathComponent("20261030_0900_sprint.md")
        generator.onGenerate = { try? "# By hand".write(to: notes, atomically: true, encoding: .utf8) }
        let queue = makeQueue(generator: generator)
        let id = try insertFailedNotesJob(into: queue)

        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()

        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "# By hand")
        XCTAssertFalse(queue.canRetryMeetingNotes(id: id))
    }

    /// The names the failed notes were to carry reach the retry's Notion export.
    func testARetryKeepsTheSpeakerNamesOfTheFailedNotes() async throws {
        let generator = throwingGenerator()
        let configuration = NotionExportConfiguration(exporter: NamesNotionExporter(), databaseID: "db", speakerTagsEnabled: true)
        let provider: () -> NotionExportResolution = { .ready(configuration) }
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { generator },
            outputDir: dir, logDir: dir, notionExportConfigurationProvider: provider,
        )
        let id = try insertFailedNotesJob(into: queue)
        try await queue.generateProtocol(
            jobID: id, transcript: "[Speaker A] Hello", title: "Sprint", protocolsDir: dir, speakerNames: ["Speaker A"],
        )
        XCTAssertEqual(queue.jobs.first?.notesSpeakerNames, ["Speaker A"])

        generator.shouldThrow = false
        queue.updateJobState(id: id, to: .done)
        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.first?.notionExportSpeakerNames, ["Speaker A"])
    }

    /// A held job has no use for its audio sidecars: the retry reads the transcript.
    func testAHeldJobLetsItsSidecarsGo() throws {
        let queue = makeQueue()
        let id = try insertFailedNotesJob(into: queue)
        let recordings = dir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let sidecars = [SpeakerNamingStore.mixSuffix, SpeakerNamingStore.segmentsSuffix]
            .map { recordings.appendingPathComponent("20261030_0900_sprint\($0)") }
        for url in sidecars {
            try Data("x".utf8).write(to: url)
        }
        queue.updateJobState(id: id, to: .generatingProtocol)

        queue.updateJobState(id: id, to: .done)

        XCTAssertTrue(queue.canRetryMeetingNotes(id: id))
        XCTAssertEqual(sidecars.filter { FileManager.default.fileExists(atPath: $0.path) }, [])
    }

    /// With the raw transcript switched off, a successful retry deletes it, so
    /// the warning that it was kept goes too.
    func testTheRetainedTranscriptWarningGoesWithASuccessfulRetry() async throws {
        let queue = PipelineQueue(
            engine: MockEngine(), diarizationFactory: { MockDiarization() }, protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir, logDir: dir, saveRawTranscriptSeparately: false,
        )
        let id = try insertFailedNotesJob(into: queue)
        queue.addWarning(id: id, PipelineQueue.rawTranscriptRetainedWithoutNotesWarning)

        XCTAssertTrue(queue.retryMeetingNotes(id: id))
        await queue.awaitProcessing()

        XCTAssertNil(queue.jobs.first?.transcriptPath)
        XCTAssertEqual(queue.jobs.first?.warnings, [])
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
            let server = state.buildDebugRPCServer(token: "t", tokenFile: nil)

            let response = await server.route(HTTPRequest(
                method: "POST", path: "/v1/jobs/\(id.uuidString)/notes/retry", headers: ["authorization": "Bearer t"],
            ))

            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(queue.jobs.first?.state, .waiting)
        }
    #endif

    // MARK: - Fixtures

    private let restoredEngine = MockEngine()

    private func throwingGenerator() -> MockProtocolGen {
        let generator = MockProtocolGen()
        generator.shouldThrow = true
        return generator
    }

    /// A second queue on the same snapshot, restored while the first still
    /// holds the job as `.waiting`. The first lets the job go before it can
    /// run it, as a quit would.
    private func relaunch(from first: PipelineQueue, keeping id: UUID) -> PipelineQueue {
        let restored = makeQueue(engine: restoredEngine)
        restored.loadSnapshot()
        XCTAssertEqual(restored.jobs.first { $0.id == id }?.state, .waiting, "the restore did not see the waiting retry")
        first.removeJob(id: id)
        return restored
    }

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
    private func insertFailedNotesJob(
        into queue: PipelineQueue, stem: String = "20261030_0900_sprint", withAudio: Bool = false,
    ) throws -> UUID {
        let transcript = dir.appendingPathComponent("\(stem).txt")
        try "[Me] Hello".write(to: transcript, atomically: true, encoding: .utf8)
        var mixPath: URL?
        if withAudio {
            mixPath = dir.appendingPathComponent("\(stem)_mix.wav")
            try Data("RIFF".utf8).write(to: XCTUnwrap(mixPath))
        }
        var job = PipelineJob(meetingTitle: "Sprint", appName: "Teams", mixPath: mixPath, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done
        job.namingSlug = stem
        job.transcriptPath = transcript
        job.warnings = [PipelineQueue.protocolGenerationFailedWarning]
        job.notesFailure = .claudeSignedOut
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

/// Records the tags each export is given.
private actor NamesNotionExporter: NotionExporting {
    private(set) var tags: [[String]] = []

    func exportMeeting( // swiftlint:disable:this function_parameter_count
        title _: String, date _: Date?, tags: [String], markdown _: String,
        transcript _: String?, existingPageID _: String?,
        onPageCreated _: @Sendable (NotionPageResult) async -> Void,
    ) -> NotionPageResult {
        self.tags.append(tags)
        return NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1")
    }
}
