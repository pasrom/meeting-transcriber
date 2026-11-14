@testable import MeetingTranscriber
import XCTest

/// How the queue a `PipelineController` builds gets its meeting-notes
/// templates: from the environment's folder, with the settings' default.
@MainActor
final class PipelineControllerProtocolTemplateTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    /// Settings over a per-test `UserDefaults` suite, never `.standard`.
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerProtocolTemplateTests")
        let suite = "PipelineControllerProtocolTemplateTests-\(getpid())-\(UUID().uuidString)"
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

    /// Compared, never opened: reading it would touch the user's own templates.
    func testTheProductionEnvironmentNamesTheAppsTemplatesFolder() {
        XCTAssertEqual(
            PipelineController.QueueEnvironment.production.protocolTemplateStore.directory,
            AppPaths.protocolTemplatesDir,
        )
    }

    /// The default template reaches a job through the queue the controller
    /// builds, read at enqueue time and checked against the environment's
    /// templates folder: a default whose file is gone stamps the built-in one.
    func testAJobTakesTheDefaultTemplateFromTheQueueTheControllerBuilds() throws {
        var environment = IsolatedQueueEnvironment.make(logDir: tmpDir)
        environment.protocolTemplateStore = try ProtocolTemplateStore(directory: makeTempDirectory(prefix: "templates"))
        try environment.protocolTemplateStore.create(name: "Board")
        let pc = PipelineController(settings: settings, notifier: RecordingNotifier(), queueEnvironment: environment)
        pc.activate { MockEngine() }
        let queue = try XCTUnwrap(pc.makeQueue())

        func enqueuedJob() -> PipelineJob? {
            queue.enqueue(PipelineJob(
                meetingTitle: "Weekly Sync", appName: "Teams",
                mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
            ))
            return queue.jobs.last
        }

        XCTAssertEqual(enqueuedJob()?.protocolTemplate, .builtIn, "the built-in one is the default")
        settings.defaultProtocolTemplate = .file(name: "Board")
        XCTAssertEqual(enqueuedJob()?.protocolTemplate, .file(name: "Board"))
        settings.defaultProtocolTemplate = .file(name: "Gone")
        XCTAssertEqual(enqueuedJob()?.protocolTemplate, .builtIn)
    }
}
