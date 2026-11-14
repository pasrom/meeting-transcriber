@testable import MeetingTranscriber
import XCTest

/// The Notion page title against protocol templates, under the rule the file
/// names follow (`ProtocolGenerator.aiTitle`): the page takes the title the
/// model wrote only when the notes came from the built-in template. A custom
/// template's first heading is a section as often as a title, so its page
/// takes the job's title, the one the export uses for notes with no heading.
@MainActor
final class PipelineQueueNotionTitleTemplateTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var store: ProtocolTemplateStore!

    private actor TitleCapturingNotionExporter: NotionExporting {
        private(set) var titles: [String] = []

        func exportMeeting( // swiftlint:disable:this function_parameter_count
            title: String, date _: Date?, tags _: [String], markdown _: String,
            transcript _: String?, existingPageID _: String?,
            onPageCreated _: @Sendable (NotionPageResult) async -> Void,
        ) -> NotionPageResult {
            titles.append(title)
            return NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1")
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline-notion-title-template")
        store = ProtocolTemplateStore(directory: tmpDir.appendingPathComponent("templates", isDirectory: true))
        try store.create(name: "Board")
        try "# Action items\n\n## Decisions\n".write(to: store.fileURL(named: "Board"), atomically: true, encoding: .utf8)
    }

    private func makeQueue(exporter: TitleCapturingNotionExporter, heading: String) -> PipelineQueue {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello everyone")]
        let protocolGen = MockProtocolGen()
        protocolGen.headingTitle = heading
        let configuration = NotionExportConfiguration(exporter: exporter, databaseID: "database-1")
        let configurationProvider: () -> NotionExportResolution = { .ready(configuration) }
        return PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging"),
            protocolTemplateStore: store,
            notionExportConfigurationProvider: configurationProvider,
            inFlightRuns: InFlightRunRegistry(),
        )
    }

    /// Runs one job whose model writes `heading` as the title, waits for its
    /// export, and returns the page titles the exporter was handed.
    private func exportedTitles(template: ProtocolTemplateID, heading: String) async throws -> [String] {
        let exporter = TitleCapturingNotionExporter()
        let queue = makeQueue(exporter: exporter, heading: heading)
        try queue.enqueue(PipelineJob(
            meetingTitle: "Board meeting", appName: "Teams",
            mixPath: createTestAudioFile(in: tmpDir), appPath: nil, micPath: nil, micDelay: 0,
            protocolTemplate: template,
        ))
        await queue.awaitProcessing()
        await queue.awaitNotionExports()
        XCTAssertEqual(queue.jobs.first?.notionExportStatus, .completed, "test premise: the export ran")
        return await exporter.titles
    }

    func testTheBuiltInTemplateTitlesThePageAfterTheModelsTitle() async throws {
        let titles = try await exportedTitles(template: .builtIn, heading: "Sprint Planning")

        XCTAssertEqual(titles, ["Sprint Planning"])
    }

    func testACustomTemplateTitlesThePageAfterTheJob() async throws {
        let titles = try await exportedTitles(template: .file(name: "Board"), heading: "Action items")

        XCTAssertEqual(titles, ["Board meeting"])
    }

    /// What decides is the prompt the job ran: a template that fell back to
    /// the built-in one asked for the built-in heading.
    func testACustomTemplateThatFellBackToTheBuiltInTitlesThePageAfterTheModelsTitle() async throws {
        let titles = try await exportedTitles(template: .file(name: "Gone"), heading: "Sprint Planning")

        XCTAssertEqual(titles, ["Sprint Planning"])
    }

    /// A retry reads the notes from the local backup, which no longer says
    /// what template made them; the job's template choice decides.
    func testARetryOfACustomTemplatesExportTitlesThePageAfterTheJob() async throws {
        let backup = tmpDir.appendingPathComponent("board.md")
        try "# Action items\n\n## Decisions\n".write(to: backup, atomically: true, encoding: .utf8)
        let exporter = TitleCapturingNotionExporter()
        let queue = makeQueue(exporter: exporter, heading: "unused")
        var job = PipelineJob(
            meetingTitle: "Board meeting", appName: "Teams", mixPath: nil,
            appPath: nil, micPath: nil, micDelay: 0, protocolTemplate: .file(name: "Board"),
        )
        job.state = .done
        job.protocolPath = backup
        job.beginNotionExport(speakerNames: [])
        job.finishNotionExport(succeeded: false)
        queue.insertJobForTesting(job)

        let retried = await queue.retryNotionExport(id: job.id)

        XCTAssertTrue(retried, "test premise: the retry ran")
        let titles = await exporter.titles
        XCTAssertEqual(titles, ["Board meeting"])
    }
}
