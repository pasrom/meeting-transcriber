@testable import MeetingTranscriber
import XCTest

/// A job whose cloud transcription failed is marked as such, and the user
/// picks where it runs next: "Retry in Cloud" or "Run Locally", the latter for
/// that job only.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class PipelineQueueCloudFailureTests: XCTestCase {
    /// Stands in for `CloudTranscriptionEngine` after its own retries.
    private final class CloudEngine: TranscribingEngine {
        var modelState: EngineModelState = .loaded
        var downloadProgress = 1.0
        var transcriptionProgress = 1.0
        var failure: CloudTranscriptionError? = .httpError(status: 503, body: "upstream down")
        var transcribeCallCount = 0

        func loadModel() {}

        func transcribeSegments(audioPath _: URL) throws -> [TimestampedSegment] {
            transcribeCallCount += 1
            if let failure { throw failure }
            return [TimestampedSegment(start: 0, end: 5, text: "From the cloud")]
        }
    }

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var cloud = CloudEngine()
    private var local = MockEngine()
    /// What the cloud toggle says when a job is admitted.
    private var settingTarget: TranscriptionTarget = .cloud

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_queue_cloud_failure_test")
        cloud = CloudEngine()
        local = MockEngine()
        local.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "From the Mac")]
        settingTarget = .cloud
    }

    private func makeQueue(outputDir: URL? = nil) -> PipelineQueue {
        PipelineQueue(
            engine: local,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: outputDir ?? tmpDir,
            logDir: tmpDir,
            engineResolver: { [cloud, local] target in
                switch target {
                case .cloud: cloud
                case .local: local
                }
            },
            transcriptionTargetProvider: { [weak self] in self?.settingTarget ?? .local },
        )
    }

    private func runOneJob(on queue: PipelineQueue) async throws -> UUID {
        let job = try PipelineJob(
            meetingTitle: "Cloud Call", appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
        )
        queue.enqueue(job)
        await queue.awaitProcessing()
        return job.id
    }

    private func job(_ id: UUID, in queue: PipelineQueue) throws -> PipelineJob {
        try XCTUnwrap(queue.jobs.first { $0.id == id })
    }

    // MARK: - The marking

    func testACloudTranscriptionFailureMarksTheJob() async throws {
        let queue = makeQueue()
        var markedAtTransition: [Bool] = []
        queue.onJobStateChange = { job, _, new in
            if new == .error { markedAtTransition.append(job.isCloudFailure) }
        }

        let id = try await runOneJob(on: queue)

        let failed = try job(id, in: queue)
        XCTAssertEqual(failed.state, .error)
        XCTAssertTrue(failed.isCloudFailure)
        XCTAssertEqual(failed.error, CloudTranscriptionError.httpError(status: 503, body: "upstream down").localizedDescription)
        XCTAssertEqual(markedAtTransition, [true], "the error transition, and its notification, did not carry the marking")
        XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(failed.mixPath).path), "the recording left the disk")
    }

    func testALocalFailureIsNotACloudFailure() async throws {
        settingTarget = .local
        local.shouldThrow = true
        let queue = makeQueue()

        let id = try await runOneJob(on: queue)

        let failed = try job(id, in: queue)
        XCTAssertEqual(failed.state, .error)
        XCTAssertFalse(failed.isCloudFailure)
    }

    /// The cloud transcribed the job; what failed afterwards (here, writing
    /// the transcript, since `protocols` is a file) ran on the Mac.
    func testACloudJobFailingAfterTranscriptionIsNotACloudFailure() async throws {
        cloud.failure = nil
        let outputDir = tmpDir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try Data().write(to: outputDir.appendingPathComponent("protocols"))
        let queue = makeQueue(outputDir: outputDir)

        let id = try await runOneJob(on: queue)

        let failed = try job(id, in: queue)
        XCTAssertEqual(failed.state, .error, "test premise: the job failed after transcription")
        XCTAssertEqual(cloud.transcribeCallCount, 1, "test premise: the cloud transcribed it")
        XCTAssertFalse(failed.isCloudFailure)
    }

    func testTheMarkingSurvivesARelaunch() async throws {
        let firstLaunch = makeQueue()
        let id = try await runOneJob(on: firstLaunch)
        await firstLaunch.awaitSnapshotFlush()

        let nextLaunch = makeQueue()
        nextLaunch.loadSnapshot()

        let restored = try job(id, in: nextLaunch)
        XCTAssertTrue(restored.isCloudFailure)
        XCTAssertEqual(restored.transcriptionTarget, .cloud)
        XCTAssertTrue(nextLaunch.canRetryJob(id: id))
    }

    // MARK: - Retry in Cloud

    func testRetryInCloudRunsTheJobInTheCloudAgain() async throws {
        let queue = makeQueue()
        let id = try await runOneJob(on: queue)
        cloud.failure = nil

        XCTAssertTrue(queue.retryJob(id: id, target: .cloud))
        await queue.awaitProcessing()

        let retried = try job(id, in: queue)
        XCTAssertEqual(retried.state, .done)
        XCTAssertFalse(retried.isCloudFailure)
        XCTAssertNil(retried.cloudTranscriptionFailed, "the retry did not clear the marking")
        XCTAssertEqual(cloud.transcribeCallCount, 2)
        XCTAssertEqual(local.transcribeCallCount, 0)
    }

    // MARK: - Run Locally

    /// The local engine's model is not loaded here: the queue does not wait for
    /// it, the engine loads it on its first transcription.
    func testRunLocallyRunsOnlyThatJobLocally() async throws {
        let queue = makeQueue()
        let id = try await runOneJob(on: queue)
        local.modelState = .unloaded

        XCTAssertTrue(queue.retryJob(id: id, target: .local))
        await queue.awaitProcessing()

        let retried = try job(id, in: queue)
        XCTAssertEqual(retried.state, .done)
        XCTAssertEqual(retried.transcriptionTarget, .local)
        XCTAssertNil(retried.cloudTranscriptionFailed)
        XCTAssertEqual(local.transcribeCallCount, 1)
        XCTAssertEqual(cloud.transcribeCallCount, 1, "the local run went to the cloud")

        cloud.failure = nil
        let laterID = try await runOneJob(on: queue)

        XCTAssertEqual(try job(laterID, in: queue).transcriptionTarget, .cloud, "Run Locally changed the target of later jobs")
        XCTAssertEqual(cloud.transcribeCallCount, 2)
        XCTAssertEqual(local.transcribeCallCount, 1)
    }

    /// The retry's own file check still applies, and a refused retry leaves
    /// the job as it was, marking and target included.
    func testARefusedRunLocallyChangesNothing() async throws {
        let queue = makeQueue()
        let id = try await runOneJob(on: queue)
        try FileManager.default.removeItem(at: XCTUnwrap(job(id, in: queue).mixPath))

        XCTAssertFalse(queue.retryJob(id: id, target: .local))

        let refused = try job(id, in: queue)
        XCTAssertEqual(refused.state, .error)
        XCTAssertTrue(refused.isCloudFailure)
        XCTAssertEqual(refused.transcriptionTarget, .cloud)
    }
}
