@testable import MeetingTranscriber
import XCTest

/// How `PipelineController` wires recording retention: the queues it builds
/// share one registry, and a settings change runs a pass by itself. Temp log,
/// staging and output folders only.
@MainActor
final class PipelineControllerRetentionTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var suiteName: String!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerRetention")
        suiteName = "PipelineControllerRetentionTests-\(getpid())-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
        settings = AppSettings(
            defaults: defaults,
            apiKeyAccount: "\(suiteName ?? "")-openAI",
            claudeAPIKeyAccount: "\(suiteName ?? "")-claude",
            defaultOutputDir: tmpDir.appendingPathComponent("Output", isDirectory: true),
        )
    }

    override func tearDown() async throws {
        settings = nil
        DefaultsSuite.remove(suiteName)
        try await super.tearDown()
    }

    private func makeController(
        securityScope: SecurityScopeAccess = .live, notifier: RecordingNotifier = RecordingNotifier(),
    ) throws -> PipelineController {
        let logDir = tmpDir.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        var environment = IsolatedQueueEnvironment.make(logDir: logDir)
        environment.securityScope = securityScope
        let controller = PipelineController(
            settings: settings,
            notifier: notifier,
            queueEnvironment: environment,
            terminalJobStore: TerminalJobStore(path: logDir.appendingPathComponent("terminal_jobs.json")),
        )
        controller.activate { MockEngine() }
        return controller
    }

    /// An eligible recording due under any threshold, on disk under the output
    /// folder.
    private func registerDueRecording(
        in controller: PipelineController,
        stem: String = "20260101_0900_sync_ab12cd34",
        recordedAt: Date = Date(timeIntervalSince1970: 1_767_258_000),
    ) throws -> URL {
        let root = settings.effectiveOutputDir
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let mix = recordings.appendingPathComponent("\(stem)_mix.wav")
        try Data("RIFF".utf8).write(to: mix)
        let protocolFile = root.appendingPathComponent("protocols/\(stem).md")
        try FileManager.default.createDirectory(
            at: protocolFile.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data("# Protocol".utf8).write(to: protocolFile)
        let jobID = UUID()
        let registry = controller.recordingRetention.registry
        registry.register(jobID: jobID, paths: [mix], root: root, recordedAt: recordedAt)
        registry.markEligible(jobID: jobID, output: protocolFile, at: Date())
        return mix
    }

    private var logDir: URL {
        tmpDir.appendingPathComponent("log", isDirectory: true)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Every queue the controller builds records into the controller's one
    /// registry, so a rebuild cannot strand entries in a registry nothing reads.
    func testBuiltQueuesShareTheControllersRetention() throws {
        let controller = try makeController()
        controller.rebuild()
        let first = controller.queue
        XCTAssertIdentical(first.recordingRetention, controller.recordingRetention)

        controller.rebuild()
        XCTAssertNotIdentical(controller.queue, first, "the second rebuild must install a new queue")
        XCTAssertIdentical(controller.queue.recordingRetention, controller.recordingRetention)
    }

    /// The cleaner asks the current queue which tracks its unfinished jobs
    /// hold, whichever queue started the pass.
    func testTheCleanerSeesTheCurrentQueuesUnfinishedJobs() throws {
        let controller = try makeController()
        controller.rebuild()
        let held = tmpDir.appendingPathComponent("Output/recordings/held_app.wav")
        var job = PipelineJob(
            meetingTitle: "Re-run", appName: "File",
            mixPath: nil, appPath: held, micPath: nil, micDelay: 0,
        )
        job.state = .transcribing
        controller.queue.insertJobForTesting(job)

        XCTAssertTrue(controller.recordingRetention.heldPaths().contains(RecordingRetentionPolicy.pathKey(held)))
    }

    /// Switching retention on clears the backlog right away, without waiting
    /// for the next finished job or the hourly pass.
    func testSwitchingRetentionOnRunsAPass() async throws {
        settings.recordingRetentionEnabled = false
        let controller = try makeController()
        controller.rebuild()
        let mix = try registerDueRecording(in: controller)
        await controller.sweepRetainedRecordings()
        XCTAssertTrue(FileManager.default.fileExists(atPath: mix.path), "switched off, nothing is deleted")

        settings.recordingRetentionEnabled = true
        await waitFor({ !self.exists(mix) }, timeout: .seconds(5))

        XCTAssertFalse(FileManager.default.fileExists(atPath: mix.path))
    }

    /// Shortening the period is a change too, and keeps being observed after
    /// the first one fired.
    func testShorteningThePeriodRunsAPass() async throws {
        settings.recordingRetentionEnabled = true
        settings.recordingRetentionDays = 36500
        let controller = try makeController()
        controller.rebuild()
        let mix = try registerDueRecording(in: controller)
        settings.recordingRetentionDays = 36000
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mix.path))

        settings.recordingRetentionDays = 0
        await waitFor({ !self.exists(mix) }, timeout: .seconds(5))

        XCTAssertFalse(FileManager.default.fileExists(atPath: mix.path))
    }

    /// A value the stepper only passes through does not act, and the value it
    /// settles on does: going 36500, 0, 20000 must delete the recording due
    /// under 20000 days and keep the one only 0 days would delete.
    func testAValueOnlyPassedThroughDoesNotActButTheSettledOneDoes() async throws {
        settings.recordingRetentionEnabled = true
        settings.recordingRetentionDays = 36500
        let controller = try makeController()
        controller.rebuild()
        // Let the pass the rebuild starts finish first, or it reads the 0 below.
        try await Task.sleep(for: .milliseconds(200))
        let recent = try registerDueRecording(in: controller)
        let ancient = try registerDueRecording(
            in: controller, stem: "19700101_0000_old_cd34ab12", recordedAt: Date(timeIntervalSince1970: 0),
        )

        settings.recordingRetentionDays = 0
        try await Task.sleep(for: .milliseconds(50))
        settings.recordingRetentionDays = 20000
        await waitFor({ !self.exists(ancient) }, timeout: .seconds(5))

        XCTAssertFalse(exists(ancient), "the settled 20000 days must have run a pass")
        XCTAssertTrue(exists(recent), "the passing value 0 must not have deleted anything")
    }

    /// The launch and hourly passes run before any queue is built, so an
    /// overdue backlog is cleaned with watching off.
    func testTheLaunchPassRunsBeforeABuiltQueueIsInstalled() async throws {
        settings.recordingRetentionEnabled = true
        settings.recordingRetentionDays = 0
        let controller = try makeController()
        let mix = try registerDueRecording(in: controller)

        await controller.sweepRetainedRecordings()

        XCTAssertFalse(exists(mix))
    }

    /// A pass is no place to report the output folder unavailable: that is
    /// told where output is written, and a pass at launch or on the hour would
    /// raise it with nothing being recorded.
    func testAPassBeforeABuiltQueueDoesNotReportTheOutputFolderUnavailable() async throws {
        settings.recordingRetentionEnabled = true
        let notifier = RecordingNotifier()
        let controller = try makeController(notifier: notifier)
        _ = try registerDueRecording(in: controller)
        settings.customOutputDirBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF]) // never resolves
        let before = notifier.calls.count

        await controller.sweepRetainedRecordings()

        XCTAssertEqual(notifier.calls.count, before, "\(notifier.calls.map(\.title))")
    }

    /// Before a queue is built the snapshot is not loaded, so a pass then reads
    /// it itself: a job the restore would bring back keeps every track it
    /// names, while a recording no job needs is still deleted.
    func testAPassBeforeABuiltQueueKeepsAudioARestorableJobNeeds() async throws {
        settings.recordingRetentionEnabled = true
        settings.recordingRetentionDays = 0
        let controller = try makeController()
        let needed = try registerDueRecording(in: controller)
        let unneeded = try registerDueRecording(in: controller, stem: "20260102_0900_other_ef56ab12")
        let waiting = PipelineJob(
            meetingTitle: "Re-import", appName: "File",
            mixPath: needed, appPath: nil, micPath: nil, micDelay: 0,
        )
        try JSONEncoder().encode([waiting]).write(to: logDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        await controller.sweepRetainedRecordings()

        XCTAssertTrue(exists(needed), "a job in the snapshot still needs it")
        XCTAssertFalse(exists(unneeded), "the pass itself ran")
    }

    /// Before a queue is built, a pass treats the output folder as a built
    /// queue would: with a custom folder's access held, entries recorded
    /// under an earlier folder are out of reach and kept.
    func testAPassBeforeABuiltQueueKeepsEntriesUnderAnEarlierFolder() async throws {
        settings.recordingRetentionEnabled = true
        settings.recordingRetentionDays = 0
        let granting = SecurityScopeAccess(start: { _ in true }, stop: { _ in })
        let controller = try makeController(securityScope: granting)
        let earlier = try registerDueRecording(in: controller)
        let chosen = tmpDir.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        settings.setCustomOutputDir(chosen)
        let current = try registerDueRecording(in: controller, stem: "20260103_0900_now_aa11bb22")

        await controller.sweepRetainedRecordings()

        XCTAssertTrue(exists(earlier), "an entry under the earlier folder is out of reach")
        XCTAssertFalse(exists(current), "the chosen folder's entry is deleted")
    }

    /// A snapshot that cannot be read leaves the pass blind to restorable
    /// jobs, so it deletes nothing until a built queue takes over.
    func testAnUnreadableSnapshotStopsAPassBeforeABuiltQueue() async throws {
        settings.recordingRetentionEnabled = true
        settings.recordingRetentionDays = 0
        let controller = try makeController()
        let mix = try registerDueRecording(in: controller)
        try Data("not json".utf8).write(to: logDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        await controller.sweepRetainedRecordings()

        XCTAssertTrue(exists(mix))
    }
}
