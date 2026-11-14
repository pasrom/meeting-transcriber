@testable import MeetingTranscriber
import XCTest

@MainActor
final class PipelineControllerNotionRestoreTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerNotionRestoreTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    private func makeSettings() throws -> AppSettings {
        let suite = "PipelineControllerNotionRestoreTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)),
            defaultOutputDir: tmpDir.appendingPathComponent("output", isDirectory: true),
        )
    }

    private func saveSnapshot(_ jobs: [PipelineJob]) throws {
        let data = try JSONEncoder().encode(jobs)
        try data.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))
    }

    private func makeSavedJob(state: JobState, exportInProgress: Bool = false) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Saved", appName: "File", mixPath: nil,
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = state
        if exportInProgress { job.beginNotionExport(speakerNames: []) }
        return job
    }

    private func makeLaunchedController() throws -> PipelineController {
        let controller = try PipelineController(
            settings: makeSettings(),
            notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir, initialQueue: nil),
        )
        controller.activate { MockEngine() }
        return controller
    }

    func testLaunchRestoresAnInterruptedNotionExportWithItsReason() throws {
        let job = makeSavedJob(state: .done, exportInProgress: true)
        try saveSnapshot([job])
        let controller = try makeLaunchedController()

        controller.restorePendingNotionExports()

        let restored = try XCTUnwrap(controller.queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(restored.notionExportStatus, .failed)
        XCTAssertEqual(restored.warnings.count, 1)
        XCTAssertTrue(restored.warnings[0].contains("interrupted when the app quit"))
    }

    func testLaunchRestoresAnInterruptedExportBesideAFinishedJob() throws {
        var finished = makeSavedJob(state: .done, exportInProgress: true)
        finished.finishNotionExport(succeeded: true)
        let interrupted = makeSavedJob(state: .done, exportInProgress: true)
        try saveSnapshot([finished, interrupted])
        let controller = try makeLaunchedController()

        controller.restorePendingNotionExports()

        XCTAssertEqual(controller.queue.jobs.map(\.id), [interrupted.id])
        XCTAssertEqual(controller.queue.jobs.first?.notionExportStatus, .failed)
    }

    /// The retry row of meeting notes that failed has to be there after a
    /// relaunch too, without the user first starting something.
    func testLaunchRestoresMeetingNotesThatFailed() throws {
        var job = makeSavedJob(state: .done)
        job.transcriptPath = tmpDir.appendingPathComponent("saved.txt")
        job.protocolFailure = "Claude CLI exited with code 1: Not logged in"
        try saveSnapshot([job])
        let controller = try makeLaunchedController()

        controller.restorePendingNotionExports()

        XCTAssertTrue(controller.queue.canRetryMeetingNotes(id: job.id))
    }

    func testLaunchLeavesTheQueueUnbuiltWhenASavedJobWouldResume() throws {
        try saveSnapshot([
            makeSavedJob(state: .done, exportInProgress: true),
            makeSavedJob(state: .waiting),
        ])
        let controller = try makeLaunchedController()

        controller.restorePendingNotionExports()

        XCTAssertNil(controller.queue.engine)
        XCTAssertTrue(controller.queue.jobs.isEmpty)
    }

    func testLaunchLeavesTheQueueUnbuiltWithoutAPendingExport() throws {
        try saveSnapshot([makeSavedJob(state: .done)])
        let controller = try makeLaunchedController()

        controller.restorePendingNotionExports()

        XCTAssertNil(controller.queue.engine)
    }
}
