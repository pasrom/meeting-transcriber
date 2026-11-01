@testable import MeetingTranscriber
import XCTest

/// A slow or hanging Notion export must not hold anything but its own job:
/// neither the queue rebuild that starts watching nor the blocking
/// `/v1/transcribe` call, and one export has an upper bound of its own.
@MainActor
final class PipelineControllerNotionExportTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional
    private let notifier = RecordingNotifier()

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerNotionExportTests")
        let suite = "PipelineControllerNotionExportTests-\(getpid())-\(UUID().uuidString)"
        settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)),
            defaultOutputDir: tmpDir.appendingPathComponent("output", isDirectory: true),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// A controller that built its own queue, which is the one whose jobs a
    /// rebuild adopts.
    private func makeBuiltController(terminalJobStore: TerminalJobStore? = nil) -> PipelineController {
        let pc = PipelineController(
            settings: settings, notifier: notifier,
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir),
            terminalJobStore: terminalJobStore,
        )
        pc.activate { MockEngine() }
        pc.rebuild()
        return pc
    }

    /// The export has created its page and is stuck appending to it, which is
    /// the state a queue swap may carry over.
    private func waitForPage(of jobID: UUID, on queue: PipelineQueue) async {
        await waitFor { queue.job(withID: jobID)?.notionPageID != nil }
    }

    // MARK: - Queue rebuild

    func testStartingToWatchReplacesTheQueueWhileAnExportIsStillRunning() async {
        let exporter = GatedNotionExporter(pageCreation: .beforeRelease)
        let pc = makeBuiltController()
        let before = pc.queue
        let jobID = pc.queue.seedFinishedJobWithRunningExport(exporter: exporter)
        await waitForPage(of: jobID, on: pc.queue)

        pc.rebuild()

        XCTAssertNotIdentical(pc.queue, before, "a running export kept the old queue and its settings")
        await exporter.release()
        await pc.queue.awaitNotionExports()
    }

    /// A page whose creation is still in flight is not known to a restart, which
    /// would create a second one without a word, so that window keeps the swap.
    func testAnExportThatHasNotCreatedItsPageYetHoldsTheQueue() async {
        await assertSwapIsHeld(forJob: makeStandupJob())
    }

    /// The page on record belongs to another database than the one the export
    /// writes to, so the export is still creating its own page.
    func testAPageOfAnotherDatabaseDoesNotCountAsTheExportsPage() async {
        var job = makeStandupJob()
        job.recordNotionPage(NotionPageResult(pageID: "old-page"), databaseID: "database-0")
        await assertSwapIsHeld(forJob: job)
    }

    private func assertSwapIsHeld(forJob job: PipelineJob) async {
        let exporter = GatedNotionExporter(pageCreation: .never)
        let pc = makeBuiltController()
        let before = pc.queue
        pc.queue.seedFinishedJobWithRunningExport(exporter: exporter, job: job)
        await waitFor { await exporter.startedExports == 1 }

        pc.rebuild()

        XCTAssertIdentical(pc.queue, before, "a swap here would let the restart create a second page")
        await exporter.release()
        await pc.queue.awaitNotionExports()
    }

    /// A retry is awaited by whoever asked for it and has no input to hand over,
    /// so replacing the queue under it would drop its result.
    func testAnExportNoBackgroundTaskOwnsStillHoldsTheQueue() {
        let pc = makeBuiltController()
        let before = pc.queue
        var job = makeStandupJob()
        job.state = .done
        job.beginNotionExport(speakerNames: [])
        pc.queue.insertJobForTesting(job)

        pc.rebuild()

        XCTAssertIdentical(pc.queue, before)
    }

    func testTheReplacementQueueKeepsTheRunningExportAndFinishesIt() async throws {
        let exporter = GatedNotionExporter(pageCreation: .beforeRelease)
        let pc = makeBuiltController()
        let before = pc.queue
        let jobID = pc.queue.seedFinishedJobWithRunningExport(exporter: exporter)
        await waitForPage(of: jobID, on: pc.queue)

        pc.rebuild()

        let carried = try XCTUnwrap(pc.queue.jobs.first { $0.id == jobID })
        XCTAssertEqual(carried.notionExportStatus, .inProgress, "the export was written off as interrupted")
        XCTAssertFalse(carried.warnings.contains { $0.hasPrefix("Notion export failed") })
        await waitFor { await exporter.startedExports == 2 }

        await exporter.release()
        await pc.queue.awaitNotionExports()
        await before.awaitNotionExports()

        XCTAssertEqual(pc.queue.jobs.first { $0.id == jobID }?.notionExportStatus, .completed)
        let reusedPages = await exporter.existingPageIDs
        XCTAssertEqual(reusedPages, [nil, "page-1"], "the restart must write into the page the first run created")
        XCTAssertEqual(
            notifier.calls.filter { $0.title == "Saved to Notion" }.count, 1,
            "the replaced queue reported its stopped export as well",
        )
        XCTAssertFalse(notifier.calls.contains { $0.title == "Notion Export Failed" })
    }

    /// The stopped run ends in its cancellation; the replaced queue must not
    /// turn that into a failure for a job the new queue is still exporting.
    func testAStoppedRunOnTheReplacedQueueRecordsNoFailure() async {
        let exporter = GatedNotionExporter(pageCreation: .beforeRelease)
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let pc = makeBuiltController(terminalJobStore: store)
        let before = pc.queue
        let jobID = pc.queue.seedFinishedJobWithRunningExport(exporter: exporter)
        await waitForPage(of: jobID, on: pc.queue)
        pc.rebuild()

        await exporter.release()
        await before.awaitNotionExports()

        XCTAssertEqual(
            before.jobs.first { $0.id == jobID }?.notionExportStatus, .inProgress,
            "a retired queue recorded an outcome for a job it no longer owns",
        )
        await pc.queue.awaitNotionExports()
        XCTAssertEqual(store.lookup(jobID: jobID)?.export?.status, "completed")
    }

    /// A re-export waits behind the first one. Both are stopped by the swap, and
    /// the one that was still waiting then continues on the replaced queue, where
    /// it must touch nothing: its job copy is stale and the shared store would
    /// take it.
    func testAnExportWaitingBehindAnotherOneTouchesNothingOnTheReplacedQueue() async throws {
        let exporter = GatedNotionExporter(pageCreation: .beforeRelease)
        let pc = makeBuiltController()
        let before = pc.queue
        let jobID = pc.queue.seedFinishedJobWithRunningExport(exporter: exporter)
        await waitForPage(of: jobID, on: pc.queue)
        pc.queue.queueNotionExport(
            PendingNotionExport(
                protocolMD: "# Standup", transcript: nil, speakerNames: ["Alice"],
                configuration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1"),
                savedLocally: true,
            ),
            jobID: jobID,
        )
        pc.queue.startPendingNotionExport(jobID: jobID)
        pc.rebuild()
        // Marks the replaced queue's copy of the job; a run that still treats
        // the queue as live puts it back to in progress when it starts.
        let index = try XCTUnwrap(before.jobs.firstIndex { $0.id == jobID })
        before.jobs[index].finishNotionExport(succeeded: false)

        await before.awaitNotionExports()

        XCTAssertEqual(before.jobs.first { $0.id == jobID }?.notionExportStatus, .failed)
        await exporter.release()
        await pc.queue.awaitNotionExports()
    }

    /// A run that returns after its queue was replaced and was not stopped in
    /// time, which no cancellation can rule out: the success arrives on the
    /// retired queue. It must not delete the local backup (the skip-local
    /// setting) or report anything, because the new queue owns the job and its
    /// export is not finished by this result.
    func testALateSuccessOnARetiredQueueDeletesNoBackupAndReportsNothing() async throws {
        let exporter = GatedNotionExporter(pageCreation: .afterRelease)
        let queue = PipelineQueue(logDir: tmpDir)
        var reported: [String?] = []
        queue.onNotionExportFinished = { _, reason in reported.append(reason) }
        let jobID = queue.seedFinishedJobWithRunningExport(exporter: exporter, skipLocalMarkdown: true)
        await waitFor { await exporter.startedExports == 1 }
        queue.retire()

        await exporter.release()
        await queue.awaitNotionExports()

        let job = try XCTUnwrap(queue.jobs.first { $0.id == jobID })
        let backup = try XCTUnwrap(job.protocolPath, "the backup was removed on a result nobody owns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(job.notionExportStatus, .inProgress)
        XCTAssertNil(job.notionPageID, "a page was recorded on a retired queue")
        XCTAssertTrue(reported.isEmpty)
    }

    // MARK: - Overall deadline

    func testAnExportThatNeverAnswersEndsAtItsOverallDeadline() async throws {
        let exporter = GatedNotionExporter()
        let queue = PipelineQueue(logDir: tmpDir)
        let jobID = queue.seedFinishedJobWithRunningExport(exporter: exporter, deadline: .milliseconds(100))

        // Polled rather than awaited: without a deadline the wait never ends,
        // and the test should fail instead of hanging the suite.
        await waitFor { queue.jobs.first { $0.id == jobID }?.notionExportStatus != .inProgress }

        let job = try XCTUnwrap(queue.jobs.first { $0.id == jobID })
        XCTAssertEqual(job.notionExportStatus, .failed)
        XCTAssertTrue(
            job.warnings.contains { $0.hasPrefix("Notion export failed (time limit reached)") },
            "warnings: \(job.warnings)",
        )
        XCTAssertTrue(queue.canRetryNotionExport(id: jobID), "the local backup must stay retryable")
        await exporter.release()
    }

    // MARK: - Blocking transcribe

    func testTranscribeAndWaitReturnsOnceTheJobIsDoneWhileTheExportStillRuns() async {
        let exporter = GatedNotionExporter()
        let queue = ExportingQueue(exporter: exporter, logDir: tmpDir)
        let pc = PipelineController(
            settings: settings, notifier: notifier,
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir, initialQueue: queue),
        )
        let file = tmpDir.appendingPathComponent("slow-export.wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("RIFF".utf8))

        let started = ContinuousClock.now
        let result = await pc.transcribeAndWait(path: file, maxWaitSeconds: 8, pollInterval: .milliseconds(10))

        guard case let .completed(dto) = result else {
            XCTFail("expected .completed, got \(result)")
            return
        }
        XCTAssertEqual(dto.state, .done)
        XCTAssertEqual(dto.export?.isInProgress, true, "the status must still say the export is pending")
        XCTAssertLessThan(started.duration(to: .now), .seconds(10), "the call waited for the export")
        await exporter.release()
        await queue.awaitNotionExports()
    }
}

private func makeStandupJob() -> PipelineJob {
    PipelineJob(
        meetingTitle: "Standup", appName: "File",
        mixPath: URL(fileURLWithPath: "/tmp/x.wav"), appPath: nil, micPath: nil, micDelay: 0,
    )
}

extension PipelineQueue {
    /// A finished job whose Notion export is running, put in place the way the
    /// pipeline does it: marked in progress first, then started.
    @discardableResult
    func seedFinishedJobWithRunningExport(
        exporter: any NotionExporting,
        job: PipelineJob? = nil,
        deadline: Duration = NotionExportConfiguration.defaultDeadline,
        skipLocalMarkdown: Bool = false,
    ) -> UUID {
        var job = job ?? makeStandupJob()
        job.state = .done
        let backup = logDir.appendingPathComponent("\(job.id.uuidString).md")
        try? "# Standup".write(to: backup, atomically: true, encoding: .utf8)
        job.protocolPath = backup
        insertJobForTesting(job)
        queueNotionExport(
            PendingNotionExport(
                protocolMD: "# Standup", transcript: nil, speakerNames: [],
                configuration: NotionExportConfiguration(
                    exporter: exporter, databaseID: "database-1", skipLocalMarkdown: skipLocalMarkdown, deadline: deadline,
                ),
                savedLocally: true,
            ),
            jobID: job.id,
        )
        startPendingNotionExport(jobID: job.id)
        return job.id
    }
}

/// A queue that finishes whatever it is given at once and leaves its Notion
/// export running.
@MainActor
private final class ExportingQueue: PipelineQueue {
    private let exporter: any NotionExporting

    init(exporter: any NotionExporting, logDir: URL) {
        self.exporter = exporter
        super.init(logDir: logDir)
    }

    override func enqueue(_ job: PipelineJob) {
        seedFinishedJobWithRunningExport(exporter: exporter, job: job)
    }
}
