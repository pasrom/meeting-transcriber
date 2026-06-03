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
}
