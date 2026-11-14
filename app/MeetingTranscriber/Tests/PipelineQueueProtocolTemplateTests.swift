@testable import MeetingTranscriber
import XCTest

/// A job's meeting-notes template, from the moment the queue admits it to the
/// instructions the generator receives. Every queue reads templates from a
/// temp folder, never the real Application Support.
@MainActor
final class PipelineQueueProtocolTemplateTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var store: ProtocolTemplateStore!
    /// What the settings name as the default template right now.
    private var currentDefault: ProtocolTemplateID = .builtIn

    private let boardText = "Board template in {LANGUAGE}."

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline-protocol-template")
        store = ProtocolTemplateStore(directory: tmpDir.appendingPathComponent("templates", isDirectory: true))
        try store.create(name: "Board")
        try boardText.write(to: store.fileURL(named: "Board"), atomically: true, encoding: .utf8)
    }

    private func makeEngine() -> MockEngine {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello everyone")]
        return engine
    }

    private func makeQueue(engine: MockEngine, protocolGen: MockProtocolGen) -> PipelineQueue {
        PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            defaultProtocolTemplateProvider: { self.currentDefault },
            protocolTemplateStore: store,
            inFlightRuns: InFlightRunRegistry(),
        )
    }

    private func makeJob(template: ProtocolTemplateID?) throws -> PipelineJob {
        try PipelineJob(
            meetingTitle: "Board meeting", appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
            protocolTemplate: template,
        )
    }

    private var builtIn: ProtocolInstructions {
        ProtocolInstructions(template: ProtocolGenerator.protocolPrompt)
    }

    // MARK: - From enqueue to the generator

    func testAJobsTemplateReachesTheGenerator() async throws {
        let protocolGen = MockProtocolGen()
        let queue = makeQueue(engine: makeEngine(), protocolGen: protocolGen)

        try queue.enqueue(makeJob(template: .file(name: "Board")))
        await queue.awaitProcessing()

        XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: boardText))
        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertEqual(queue.jobs.first?.warnings, [])
    }

    func testTheDefaultIsFixedWhenTheJobIsQueued() async throws {
        let protocolGen = MockProtocolGen()
        let queue = makeQueue(engine: makeEngine(), protocolGen: protocolGen)
        currentDefault = .file(name: "Board")

        try queue.enqueue(makeJob(template: nil))
        currentDefault = .builtIn
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.first?.protocolTemplate, .file(name: "Board"))
        XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: boardText))
    }

    func testARetriedJobKeepsItsTemplate() async throws {
        let engine = makeEngine()
        engine.shouldThrow = true
        let protocolGen = MockProtocolGen()
        let queue = makeQueue(engine: engine, protocolGen: protocolGen)
        let job = try makeJob(template: .file(name: "Board"))
        queue.enqueue(job)
        await queue.awaitProcessing()
        XCTAssertEqual(queue.jobs.first?.state, .error, "test premise: the first run failed")

        engine.shouldThrow = false
        XCTAssertTrue(queue.retryJob(id: job.id))
        await queue.awaitProcessing()

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: boardText))
    }

    // MARK: - Falling back

    func testAMissingOrBlankTemplateFallsBackToTheBuiltInWithAWarning() async throws {
        try " \n\t\n".write(to: store.fileURL(named: "Blank"), atomically: true, encoding: .utf8)
        for name in ["Gone", "Blank"] {
            let protocolGen = MockProtocolGen()
            let queue = makeQueue(engine: makeEngine(), protocolGen: protocolGen)

            try queue.enqueue(makeJob(template: .file(name: name)))
            await queue.awaitProcessing()

            let job = try XCTUnwrap(queue.jobs.first)
            XCTAssertEqual(job.state, .done, name)
            XCTAssertEqual(protocolGen.capturedInstructions, builtIn, name)
            XCTAssertEqual(
                job.warnings,
                ["Meeting notes template \"\(name)\" was not found or is empty, so the built-in template was used"],
                name,
            )
        }
    }

    /// A job restored from a snapshot written before templates carries no
    /// template, and gets what it got then: the current default.
    func testAJobFromAnOlderSnapshotUsesTheCurrentDefault() async throws {
        let job = try makeJob(template: nil)
        let snapshot = try JSONEncoder().encode([job])
        let json = try XCTUnwrap(String(data: snapshot, encoding: .utf8))
        XCTAssertFalse(json.contains("protocolTemplate"), "test premise: written without the new key")
        try snapshot.write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))
        let protocolGen = MockProtocolGen()
        let restored = makeQueue(engine: makeEngine(), protocolGen: protocolGen)
        currentDefault = .file(name: "Board")

        restored.loadSnapshot()
        await restored.awaitProcessing()

        XCTAssertEqual(restored.jobs.first?.state, .done)
        XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: boardText))
    }

    func testARecoveredOrphanIsStampedWithTheDefault() async throws {
        let recordings = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 100).write(to: recordings.appendingPathComponent("20260311_100000_mix.wav"))
        let queue = PipelineQueue(
            logDir: tmpDir,
            inFlightRuns: InFlightRunRegistry(),
            defaultProtocolTemplateProvider: { .file(name: "Board") },
            protocolTemplateStore: store,
        )

        await queue.recoverOrphanedRecordings(recordingsDir: recordings)

        XCTAssertEqual(queue.jobs.map(\.protocolTemplate), [.file(name: "Board")])
    }

    // MARK: - Restore

    /// The resume after a quit during generation reads the job's own template,
    /// not the default of the next launch.
    func testTheNotesOnlyResumeUsesTheJobsTemplate() async throws {
        let first = makeQueue(engine: makeEngine(), protocolGen: MockProtocolGen())
        let job = try makeJob(template: .file(name: "Board"))
        first.enqueue(job)
        await first.awaitProcessing()
        await first.awaitSnapshotFlush()
        var interrupted = try XCTUnwrap(first.jobs.first)
        interrupted.state = .generatingProtocol
        interrupted.protocolPath = nil
        try JSONEncoder().encode([interrupted]).write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let engine = makeEngine()
        let protocolGen = MockProtocolGen()
        let restored = makeQueue(engine: engine, protocolGen: protocolGen)
        restored.loadSnapshot()
        await restored.awaitProcessing()

        XCTAssertEqual(engine.transcribeCallCount, 0, "test premise: the restore resumed the notes only")
        XCTAssertEqual(protocolGen.capturedInstructions, ProtocolInstructions(template: boardText))
    }
}
