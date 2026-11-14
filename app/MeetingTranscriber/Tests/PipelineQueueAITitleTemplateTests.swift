@testable import MeetingTranscriber
import XCTest

/// "Use AI meeting title for filenames" against protocol templates. Only the
/// built-in prompt asks the model for a `# <label> - <title>` heading; a
/// custom template's first heading is whatever the template writes, often a
/// section such as "Action items". So the files are named after the model's
/// title only when the job ran the built-in prompt, and a job that ran a
/// custom template keeps its date-based name.
@MainActor
final class PipelineQueueAITitleTemplateTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var store: ProtocolTemplateStore!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline-ai-title-template")
        store = ProtocolTemplateStore(directory: tmpDir.appendingPathComponent("templates", isDirectory: true))
        try store.create(name: "Board")
        try "# Action items\n\n## Decisions\n".write(to: store.fileURL(named: "Board"), atomically: true, encoding: .utf8)
    }

    /// Runs one job with the AI title switched on, its model writing
    /// `heading` as the title, and returns the job as it ended.
    private func runJob(template: ProtocolTemplateID, heading: String) async throws -> PipelineJob {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello everyone")]
        let protocolGen = MockProtocolGen()
        protocolGen.headingTitle = heading
        let queue = PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            protocolTemplateStore: store,
            inFlightRuns: InFlightRunRegistry(),
        )
        try queue.enqueue(PipelineJob(
            meetingTitle: "Board meeting", appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
            useAITitleForFilenames: true, protocolTemplate: template,
        ))
        await queue.awaitProcessing()
        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.state, .done, "test premise: the job made its protocol")
        return job
    }

    func testTheBuiltInTemplateNamesTheFilesAfterTheModelsTitle() async throws {
        let job = try await runJob(template: .builtIn, heading: "Sprint Planning")

        XCTAssertEqual(job.namingSlug, "sprint_planning")
        XCTAssertEqual(job.protocolPath?.lastPathComponent, "sprint_planning.md")
    }

    func testACustomTemplateKeepsTheDateBasedName() async throws {
        let job = try await runJob(template: .file(name: "Board"), heading: "Action items")

        let slug = try XCTUnwrap(job.namingSlug)
        XCTAssertTrue(slug.hasSuffix(job.shortID), "the date-based name carries the short id: \(slug)")
        XCTAssertFalse(slug.contains("action_items"), slug)
        XCTAssertEqual(job.protocolPath?.lastPathComponent, "\(slug).md")
    }

    /// What decides is the prompt the job ran: a template that fell back to
    /// the built-in one asked for the built-in heading.
    func testACustomTemplateThatFellBackToTheBuiltInNamesTheFilesAfterTheTitle() async throws {
        let job = try await runJob(template: .file(name: "Gone"), heading: "Sprint Planning")

        XCTAssertEqual(job.warnings.count, 1, "test premise: the template fell back with a warning")
        XCTAssertEqual(job.namingSlug, "sprint_planning")
    }
}
