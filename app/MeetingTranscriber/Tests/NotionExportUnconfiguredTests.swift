@testable import MeetingTranscriber
import XCTest

/// An export that is switched on but cannot run must say so on the job, whatever
/// the protocol provider does. These tests go through the real
/// `NotionExportConfiguration.resolve` and, for the controller ones, the real
/// wiring in `PipelineController`, because a resolution injected by hand cannot
/// notice either of them answering the wrong case.
@MainActor
final class NotionExportUnconfiguredTests: XCTestCase {
    // swiftlint:disable:previous balanced_xctest_lifecycle
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "NotionExportUnconfiguredTests")
    }

    // MARK: - Fixtures

    private enum KeyState { case absent, present }

    private func makeSettings(
        enabled: Bool = true, key: KeyState = .absent, databaseID: String = "",
    ) throws -> AppSettings {
        let suite = "NotionExportUnconfiguredTests-\(UUID().uuidString)"
        let keyAccount = "notionKey.\(UUID().uuidString)"
        addTeardownBlock {
            DefaultsSuite.remove(suite)
            KeychainHelper.delete(key: keyAccount)
        }
        let settings = try AppSettings(
            defaults: XCTUnwrap(UserDefaults(suiteName: suite)),
            notionAPIKeyAccount: keyAccount,
            defaultOutputDir: tmpDir.appendingPathComponent("output", isDirectory: true),
        )
        settings.notionExportEnabled = enabled
        if key == .present { settings.notionAPIKey = "test-key" }
        settings.notionDatabaseID = databaseID
        settings.diarize = false
        return settings
    }

    private func makeJob() throws -> PipelineJob {
        try PipelineJob(
            meetingTitle: "Weekly Sync", appName: "File",
            mixPath: createTestAudioFile(in: tmpDir),
            appPath: nil, micPath: nil, micDelay: 0,
        )
    }

    /// A queue whose export configuration comes from the real `resolve`.
    private func makeQueue(
        settings: AppSettings, protocolGen: MockProtocolGen?,
    ) -> PipelineQueue {
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        let resolve: () -> NotionExportResolution = { NotionExportConfiguration.resolve(settings: settings) }
        return PipelineQueue(
            engine: engine,
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: tmpDir,
            logDir: tmpDir,
            stagingDir: tmpDir.appendingPathComponent("staging", isDirectory: true),
            diarizeEnabled: false,
            micLabel: "Me",
            notionExportConfigurationProvider: resolve,
        )
    }

    private func run(_ job: PipelineJob, on queue: PipelineQueue) async throws -> PipelineJob {
        queue.enqueue(job)
        await queue.awaitProcessing()
        return try XCTUnwrap(queue.jobs.first)
    }

    private var unconfiguredWarning: String {
        PipelineQueue.notionExportUnconfiguredWarning
    }

    // MARK: - resolve(settings:)

    func testResolveIsDisabledWhenTheExportIsOff() throws {
        let settings = try makeSettings(enabled: false, key: .present, databaseID: "database-1")
        XCTAssertEqual(NotionExportConfiguration.resolve(settings: settings).label, "disabled", "a switched-off export is disabled, not unconfigured")
    }

    func testResolveIsUnconfiguredWithoutAToken() throws {
        let settings = try makeSettings(key: .absent, databaseID: "database-1")
        XCTAssertEqual(NotionExportConfiguration.resolve(settings: settings).label, "unconfigured", "an export that is on without a token is unconfigured")
    }

    func testResolveTreatsAWhitespaceOnlyTokenAsNoToken() throws {
        let settings = try makeSettings(key: .absent, databaseID: "database-1")
        settings.notionAPIKey = "  \n "
        XCTAssertEqual(NotionExportConfiguration.resolve(settings: settings).label, "unconfigured")
    }

    func testResolveIsUnconfiguredWithoutADatabase() throws {
        let settings = try makeSettings(key: .present, databaseID: "")
        XCTAssertEqual(NotionExportConfiguration.resolve(settings: settings).label, "unconfigured", "an export that is on without a database is unconfigured")
    }

    func testResolveIsReadyWithTokenAndDatabaseAndCarriesTheOutputPolicy() throws {
        let settings = try makeSettings(key: .present, databaseID: "database-1")
        settings.notionSkipLocalMarkdownOnSuccess = true
        settings.notionSpeakerTagsEnabled = true
        let resolution = NotionExportConfiguration.resolve(settings: settings)
        XCTAssertEqual(resolution.label, "ready", "token and database make the export ready")
        let configuration = try XCTUnwrap(resolution.configuration)
        XCTAssertEqual(configuration.databaseID, "database-1")
        XCTAssertTrue(configuration.skipLocalMarkdown)
        XCTAssertTrue(configuration.speakerTagsEnabled)
    }

    // MARK: - The job says why, whatever the protocol provider does

    func testUnconfiguredExportWarnsWithAGeneratingProvider() async throws {
        let settings = try makeSettings()
        let finished = try await run(makeJob(), on: makeQueue(settings: settings, protocolGen: MockProtocolGen()))
        XCTAssertTrue(finished.warnings.contains(unconfiguredWarning))
        XCTAssertNotNil(finished.protocolPath, "the local protocol is kept")
    }

    func testUnconfiguredExportWarnsWhenTheProviderIsNone() async throws {
        let settings = try makeSettings()
        let finished = try await run(makeJob(), on: makeQueue(settings: settings, protocolGen: nil))
        XCTAssertTrue(finished.warnings.contains(unconfiguredWarning))
        XCTAssertEqual(finished.state, .done, finished.error ?? "")
    }

    func testUnconfiguredExportWarnsWhenProtocolGenerationFails() async throws {
        let settings = try makeSettings()
        let failing = MockProtocolGen()
        failing.shouldThrow = true
        let finished = try await run(makeJob(), on: makeQueue(settings: settings, protocolGen: failing))
        XCTAssertTrue(finished.warnings.contains(unconfiguredWarning))
        XCTAssertTrue(finished.warnings.contains { $0.hasPrefix("Protocol generation failed") })
    }

    func testTheWarningIsNotRepeatedWhenGenerationRunsAgain() async throws {
        let settings = try makeSettings()
        let queue = makeQueue(settings: settings, protocolGen: nil)
        let finished = try await run(makeJob(), on: queue)
        try await queue.generateProtocol(
            jobID: finished.id, transcript: "again", title: "Weekly Sync",
            protocolsDir: tmpDir.appendingPathComponent("protocols"),
        )
        XCTAssertEqual(queue.jobs.first?.warnings.filter { $0 == unconfiguredWarning }.count, 1)
    }

    func testSwitchedOffExportAddsNoWarningWhateverTheProviderDoes() async throws {
        let failing = MockProtocolGen()
        failing.shouldThrow = true
        for protocolGen in [MockProtocolGen(), nil, failing] {
            let settings = try makeSettings(enabled: false)
            let finished = try await run(makeJob(), on: makeQueue(settings: settings, protocolGen: protocolGen))
            XCTAssertFalse(finished.warnings.contains(unconfiguredWarning))
            XCTAssertNil(finished.notionExportStatus)
        }
    }

    // MARK: - The controller wiring

    private func makeController(settings: AppSettings) -> PipelineController {
        let controller = PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir, initialQueue: nil),
        )
        let engine = MockEngine()
        engine.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Hello world")]
        controller.activate { engine }
        return controller
    }

    func testTheControllerHandsTheQueueTheResolutionOfTheCurrentSettings() throws {
        let settings = try makeSettings(enabled: false, key: .present, databaseID: "database-1")
        let queue = try XCTUnwrap(makeController(settings: settings).makeQueue())
        let provider = try XCTUnwrap(queue.notionExportConfigurationProvider)

        XCTAssertEqual(provider().label, "disabled", "switched off")
        settings.notionExportEnabled = true
        XCTAssertEqual(provider().label, "ready", "token and database")
        settings.notionDatabaseID = ""
        XCTAssertEqual(provider().label, "unconfigured", "no database")
        settings.notionDatabaseID = "database-1"
        settings.notionAPIKey = ""
        XCTAssertEqual(provider().label, "unconfigured", "no token")
    }

    func testAJobRunThroughTheControllerWithProviderNoneWarnsAboutTheMissingToken() async throws {
        let settings = try makeSettings(databaseID: "database-1")
        settings.protocolProvider = .none
        let controller = makeController(settings: settings)
        controller.rebuild()

        try controller.queue.enqueue(makeJob())
        await controller.queue.awaitProcessing()

        let finished = try XCTUnwrap(controller.queue.jobs.first)
        XCTAssertTrue(finished.warnings.contains(unconfiguredWarning))
        XCTAssertEqual(finished.state, .done, finished.error ?? "")
    }

    func testAJobRunThroughTheControllerWithAFailingGeneratorWarnsAboutTheMissingDatabase() async throws {
        let settings = try makeSettings(key: .present, databaseID: "")
        settings.protocolProvider = .openAICompatible
        // Nothing listens on port 1, so generation fails at once and locally.
        settings.openAIEndpoint = "http://127.0.0.1:1/v1/chat/completions"
        let controller = makeController(settings: settings)
        controller.rebuild()

        try controller.queue.enqueue(makeJob())
        await controller.queue.awaitProcessing()

        let finished = try XCTUnwrap(controller.queue.jobs.first)
        XCTAssertTrue(finished.warnings.contains { $0.hasPrefix("Protocol generation failed") })
        XCTAssertTrue(finished.warnings.contains(unconfiguredWarning))
    }
}

private extension NotionExportResolution {
    var label: String {
        switch self {
        case .disabled: "disabled"
        case .unconfigured: "unconfigured"
        case .ready: "ready"
        }
    }
}
