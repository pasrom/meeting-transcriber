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
            defaults: XCTUnwrap(UserDefaults(suiteName: suite)),
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

    // MARK: - Queue rebuild

    func testStartingToWatchReplacesTheQueueWhileAnExportIsStillRunning() async {
        let exporter = GatedNotionExporter()
        let pc = makeBuiltController()
        let before = pc.queue
        pc.queue.seedFinishedJobWithRunningExport(exporter: exporter)

        pc.rebuild()

        XCTAssertNotIdentical(pc.queue, before, "a running export kept the old queue and its settings")
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
        let exporter = GatedNotionExporter()
        let pc = makeBuiltController()
        let before = pc.queue
        let jobID = pc.queue.seedFinishedJobWithRunningExport(exporter: exporter)
        await waitFor { await exporter.startedExports == 1 }

        pc.rebuild()

        let carried = try XCTUnwrap(pc.queue.jobs.first { $0.id == jobID })
        XCTAssertEqual(carried.notionExportStatus, .inProgress, "the export was written off as interrupted")
        XCTAssertFalse(carried.warnings.contains { $0.hasPrefix("Notion export failed") })
        await waitFor { await exporter.startedExports == 2 }

        await exporter.release()
        await pc.queue.awaitNotionExports()
        await before.awaitNotionExports()

        XCTAssertEqual(pc.queue.jobs.first { $0.id == jobID }?.notionExportStatus, .completed)
        XCTAssertEqual(
            notifier.calls.filter { $0.title == "Saved to Notion" }.count, 1,
            "the replaced queue reported its stopped export as well",
        )
        XCTAssertFalse(notifier.calls.contains { $0.title == "Notion Export Failed" })
    }

    func testAnExportTheOldQueueFinishesAfterTheSwapChangesNothingOnTheNewOne() async {
        let exporter = GatedNotionExporter()
        let store = TerminalJobStore(path: tmpDir.appendingPathComponent("terminal_jobs.json"))
        let pc = makeBuiltController(terminalJobStore: store)
        let before = pc.queue
        let jobID = pc.queue.seedFinishedJobWithRunningExport(exporter: exporter)
        await waitFor { await exporter.startedExports == 1 }
        pc.rebuild()

        // Both calls are released together; what the old queue's call returns
        // must land nowhere, the new queue's own run is the one that counts.
        await exporter.release()
        await before.awaitNotionExports()

        XCTAssertEqual(
            before.jobs.first { $0.id == jobID }?.notionExportStatus, .inProgress,
            "a retired queue recorded an outcome for a job it no longer owns",
        )
        await pc.queue.awaitNotionExports()
        XCTAssertEqual(store.lookup(jobID: jobID)?.export?.status, "completed")
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
                configuration: NotionExportConfiguration(exporter: exporter, databaseID: "database-1", deadline: deadline),
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
