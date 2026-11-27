@testable import MeetingTranscriber
import XCTest

/// How `PipelineController` wires the compactor: the queues it builds share
/// it, it reads the FLAC setting live, a launch run picks up marked entries
/// before any queue is built, and its work in progress counts as held for
/// retention. Temp log, staging and output folders only.
@MainActor
final class PipelineControllerCompactionTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var suiteName: String!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerCompaction")
        suiteName = "PipelineControllerCompactionTests-\(getpid())-\(UUID().uuidString)"
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

    private var logDir: URL {
        tmpDir.appendingPathComponent("log", isDirectory: true)
    }

    private func makeController(
        steps: RecordingCompactionWorker.Steps = .live, activate: Bool = true,
    ) throws -> PipelineController {
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        var environment = IsolatedQueueEnvironment.make(logDir: logDir)
        environment.compactionWorker = RecordingCompactionWorker(steps: steps)
        let controller = PipelineController(
            settings: settings, notifier: RecordingNotifier(), queueEnvironment: environment,
            terminalJobStore: TerminalJobStore(path: logDir.appendingPathComponent("terminal_jobs.json")),
        )
        if activate { controller.activate { MockEngine() } }
        return controller
    }

    /// A finished, eligible recording in the output folder, 16-bit, listed
    /// and marked as owed the conversion.
    private func registerMarkedRecording(in controller: PipelineController) throws -> URL {
        let root = settings.effectiveOutputDir
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let mix = recordings.appendingPathComponent("20260101_0900_sync_ab12cd34_mix.wav")
        let samples = (0 ..< AudioConstants.targetSampleRate).map { Float(Int16(clamping: $0 % 4000)) / 32768 }
        try AudioMixer.saveWAV(samples: samples, sampleRate: AudioConstants.targetSampleRate, url: mix)
        let protocolFile = root.appendingPathComponent("protocols/20260101_0900_sync_ab12cd34.md")
        try FileManager.default.createDirectory(at: protocolFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Protocol".utf8).write(to: protocolFile)
        let jobID = UUID()
        let registry = controller.recordingRetention.registry
        registry.register(jobID: jobID, paths: [mix], root: root, recordedAt: Date(timeIntervalSince1970: 1_767_258_000))
        registry.markEligible(jobID: jobID, output: protocolFile, at: Date())
        registry.markAwaiting(.flac, jobID: jobID, root: root)
        return mix
    }

    func testBuiltQueuesShareTheControllersCompactorAndItReadsTheSettingLive() throws {
        let controller = try makeController()
        controller.recordingCompaction.codecStatus = .available
        controller.rebuild()

        XCTAssertIdentical(controller.queue.recordingCompaction, controller.recordingCompaction)
        XCTAssertFalse(controller.recordingCompaction.wantsWork, "off by default")
        settings.compressKeptRecordings = true
        XCTAssertEqual(controller.queue.recordingCompaction?.wantsWork, true, "switched on after the queue was built")
    }

    /// The probe gates the runs: with no FLAC, nothing is converted.
    func testWithoutFLACTheSettingDoesNothing() async throws {
        settings.compressKeptRecordings = true
        let controller = try makeController(activate: false)
        let mix = try registerMarkedRecording(in: controller)
        controller.recordingCompaction.codecStatus = .unavailable(reason: "notNativeFLAC")

        await controller.compactRecordings()

        XCTAssertTrue(CompactionDisk.exists(mix))
        XCTAssertEqual(controller.recordingCompaction.awaitingCount, 1)
    }

    /// A launch with no queue built yet runs once after the probe, for the
    /// entries a quit left marked.
    func testAnAwaitingEntryIsCompressedAtTheNextLaunch() async throws {
        settings.compressKeptRecordings = true
        let controller = try makeController(activate: false)
        let mix = try registerMarkedRecording(in: controller)
        let flac = try XCTUnwrap(KeptRecordingCompressor.compressedURL(for: mix))

        controller.activate { MockEngine() }
        await waitFor(CompactionDisk.exists(flac) && !CompactionDisk.exists(mix), timeout: .seconds(10))

        XCTAssertFalse(CompactionDisk.exists(mix))
        XCTAssertTrue(KeptRecordingCompressor.isNativeFLAC(flac))
        XCTAssertEqual(controller.recordingCompaction.codecStatus, .available)
        await waitFor(controller.recordingCompaction.awaitingCount == 0, timeout: .seconds(5))
        XCTAssertEqual(controller.recordingCompaction.awaitingCount, 0)
    }

    /// Before a queue is built, a job the restore will bring back is only in
    /// the snapshot; a run then must still keep its tracks as they are.
    func testARunBeforeABuiltQueueKeepsTheTracksOfAJobInTheSnapshot() async throws {
        settings.compressKeptRecordings = true
        let controller = try makeController(activate: false)
        let mix = try registerMarkedRecording(in: controller)
        try PipelineSnapshot.save(
            [PipelineJob(meetingTitle: "Weekly Sync", appName: "Teams", mixPath: mix, appPath: nil, micPath: nil, micDelay: 0)],
            to: logDir,
        )
        controller.recordingCompaction.codecStatus = .available

        await controller.compactRecordings()

        XCTAssertTrue(CompactionDisk.exists(mix), "a track the restored job will read was converted")
        XCTAssertEqual(controller.recordingCompaction.awaitingCount, 1)
    }

    /// A retention pass that comes due while the compactor is working on an
    /// entry keeps the whole entry: the compactor's work counts as held.
    func testARetentionPassDuringTheRunKeepsTheEntry() async throws {
        settings.compressKeptRecordings = true
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let controller = try makeController(steps: steps, activate: false)
        let mix = try registerMarkedRecording(in: controller)
        controller.activate { MockEngine() }
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        // Due from now on: on, and right away.
        settings.recordingRetentionEnabled = true
        settings.recordingRetentionDays = 0
        controller.recordingRetention.settle()
        await controller.sweepRetainedRecordings()

        XCTAssertTrue(CompactionDisk.exists(mix), "a pass deleted the WAV the compactor is reading")
        gate.open()
        await waitFor(!controller.recordingCompaction.isRunning, timeout: .seconds(10))
        let flac = try XCTUnwrap(KeptRecordingCompressor.compressedURL(for: mix))
        XCTAssertFalse(CompactionDisk.exists(flac), "a recording come due is not converted first")
        XCTAssertTrue(CompactionDisk.exists(mix))
    }
}
