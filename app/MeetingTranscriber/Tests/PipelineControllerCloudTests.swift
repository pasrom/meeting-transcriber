@testable import MeetingTranscriber
import XCTest

/// Cloud transcription through the production queue factory
/// (`PipelineController.makeQueue`), not a queue a test wired itself.
@MainActor
final class PipelineControllerCloudTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerCloudTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    private func makeController(engine: @escaping () -> any TranscribingEngine) throws -> (PipelineController, AppSettings) {
        let suite = "PipelineControllerCloudTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)),
            defaultOutputDir: tmpDir.appendingPathComponent("output", isDirectory: true),
        )
        let controller = PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir, initialQueue: nil),
        )
        controller.activate(engineProvider: engine)
        return (controller, settings)
    }

    private func makeJob(target: TranscriptionTarget?, mixPath: URL? = nil) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Saved", appName: "File", mixPath: mixPath ?? tmpDir.appendingPathComponent("mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.transcriptionTarget = target
        return job
    }

    func testAQueueBuiltWithCloudOnSendsItsJobsToTheCloudEngine() throws {
        let (controller, settings) = try makeController { MockEngine() }
        settings.cloudTranscriptionEnabled = true
        let queue = try XCTUnwrap(controller.makeQueue())

        queue.enqueue(makeJob(target: nil))

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.transcriptionTarget, .cloud)
        XCTAssertTrue(queue.transcriptionEngine(for: job) is CloudTranscriptionEngine)
    }

    /// Run Locally names the engine Settings shows, so a queue built before an
    /// engine switch must not keep using the earlier one.
    func testALocalJobUsesTheEngineSelectedNowNotTheOneTheQueueWasBuiltWith() throws {
        let first = MockEngine()
        let second = MockEngine()
        var active: MockEngine = first
        let (controller, _) = try makeController { active }
        let queue = try XCTUnwrap(controller.makeQueue())

        active = second

        XCTAssertIdentical(queue.transcriptionEngine(for: makeJob(target: .local)), second)
    }

    /// With auto-watch off nothing else builds the first queue, so without the
    /// restore the failed job's Retry in Cloud and Run Locally stay hidden.
    func testLaunchRestoresLocalAndCloudFailuresWithoutStartingEither() throws {
        var local = try makeJob(target: .local, mixPath: createTestAudioFile(in: tmpDir))
        local.state = .error
        var failed = try makeJob(target: .cloud, mixPath: createTestAudioFile(in: tmpDir))
        failed.state = .error
        failed.cloudTranscriptionFailed = true
        try JSONEncoder().encode([local, failed]).write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))
        let (controller, _) = try makeController { MockEngine() }

        controller.restorePendingNotionExports()

        XCTAssertEqual(controller.queue.jobs.map(\.id), [local.id, failed.id])
        XCTAssertEqual(controller.queue.jobs.map(\.state), [.error, .error])
        XCTAssertFalse(controller.queue.isProcessing)
        let restored = try XCTUnwrap(controller.queue.jobs.first { $0.id == failed.id })
        XCTAssertTrue(restored.isCloudFailure)
        XCTAssertTrue(controller.queue.canRetryJob(id: failed.id))
    }
}
