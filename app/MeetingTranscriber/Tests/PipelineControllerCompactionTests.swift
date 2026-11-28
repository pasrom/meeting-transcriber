@testable import MeetingTranscriber
import os
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
        probe: KeptRecordingCodecStatus = .available, probeHeld: DispatchSemaphore? = nil,
        scopeOpens: Bool = true, queueRoot: URL? = nil,
    ) throws -> PipelineController {
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        var environment = IsolatedQueueEnvironment.make(logDir: logDir)
        environment.compactionWorker = RecordingCompactionWorker(steps: steps)
        environment.probeKeptRecordingCodec = {
            probeHeld?.wait()
            return probe
        }
        if let queueRoot { environment.resolveOutputDir = { _ in queueRoot } }
        if !scopeOpens { environment.securityScope = SecurityScopeAccess(start: { _ in false }, stop: { _ in }) }
        let controller = PipelineController(
            settings: settings, notifier: RecordingNotifier(), queueEnvironment: environment,
            terminalJobStore: TerminalJobStore(path: logDir.appendingPathComponent("terminal_jobs.json")),
        )
        if activate { controller.activate { MockEngine() } }
        return controller
    }

    /// A finished, eligible recording in the output folder, 16-bit, listed
    /// and marked as owed the conversion.
    private func registerMarkedRecording(
        in controller: PipelineController,
        stem: String = "20260101_0900_sync_ab12cd34",
        recordedAt: Date = Date(timeIntervalSince1970: 1_767_258_000),
        eligibleAt: Date = Date(),
        marked: Bool = true,
        under otherRoot: URL? = nil,
    ) throws -> URL {
        let root = otherRoot ?? settings.effectiveOutputDir
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let mix = recordings.appendingPathComponent("\(stem)_mix.wav")
        let samples = (0 ..< AudioConstants.targetSampleRate).map { Float(Int16(clamping: $0 % 4000)) / 32768 }
        try AudioMixer.saveWAV(samples: samples, sampleRate: AudioConstants.targetSampleRate, url: mix)
        let protocolFile = root.appendingPathComponent("protocols/\(stem).md")
        try FileManager.default.createDirectory(at: protocolFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Protocol".utf8).write(to: protocolFile)
        let jobID = UUID()
        let registry = controller.recordingRetention.registry
        registry.register(jobID: jobID, paths: [mix], root: root, recordedAt: recordedAt)
        registry.markEligible(jobID: jobID, output: protocolFile, at: eligibleAt)
        if marked { registry.markAwaiting(.flac, jobID: jobID, root: root) }
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

    /// A storage-limit pass that lands after the compactor has listed and
    /// named a track's FLAC but before it unlinks the WAV keeps both copies:
    /// the compactor's entry in work is held for the size pass too. Entry A
    /// is older than entry C on purpose: were A deletable, the pass would
    /// pick it first and, with C alone not enough, take its WAV and its FLAC.
    func testASizePassBetweenTheCommitAndTheUnlinkKeepsBothCopies() async throws {
        settings.compressKeptRecordings = true
        settings.recordingRetentionEnabled = false
        settings.recordingStorageLimitEnabled = true
        settings.recordingStorageLimitGB = 1
        let syncing = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        // A failed assert before the release must not park the compactor
        // for the tests that share this process.
        defer { release.signal() }
        let steps = RecordingCompactionWorker.Steps.live.with(\.syncFolder) { folder in
            let first = syncing.withLock { state -> Bool in
                defer { state = true }
                return !state
            }
            if first { release.wait() }
            KeptRecordingCompressor.syncFolder(folder)
        }
        let controller = try makeController(steps: steps, activate: false)
        let twoDaysAgo = Date().addingTimeInterval(-48 * 3600)
        let mix = try registerMarkedRecording(in: controller, eligibleAt: twoDaysAgo)
        let flac = try XCTUnwrap(KeptRecordingCompressor.compressedURL(for: mix))
        let large = try registerMarkedRecording(
            in: controller, stem: "20260102_0900_large_cd34ab12",
            recordedAt: Date(timeIntervalSince1970: 1_767_344_400), eligibleAt: twoDaysAgo, marked: false,
        )
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 1_000_000_001)
        try handle.close()

        // The launch pass warns (the large recording alone is over), and
        // the launch run commits the FLAC and stops in the folder sync.
        controller.activate { MockEngine() }
        await waitFor(syncing.withLock { $0 } && settings.recordingStorageAlarm.load() != nil, timeout: .seconds(10))
        let warning = try XCTUnwrap(settings.recordingStorageAlarm.load())
        settings.recordingStorageAlarm.save(RecordingStorageWarning(
            since: warning.since.addingTimeInterval(-25 * 3600), limitBytes: warning.limitBytes, root: warning.root,
        ))
        XCTAssertTrue(CompactionDisk.exists(mix) && CompactionDisk.exists(flac), "test premise: both copies on disk")
        let listed = Set(controller.recordingRetention.registry.entries.flatMap(\.paths).map(\.lastPathComponent))
        XCTAssertTrue(
            listed.isSuperset(of: [mix.lastPathComponent, flac.lastPathComponent]), "test premise: both copies listed",
        )
        // No longer taking marked entries: the pair counts once only because
        // the entry is the one in work. A run checks the codec when it
        // starts, so the one parked here goes on.
        controller.recordingCompaction.codecStatus = .unavailable(reason: "notNativeFLAC")

        await controller.sweepRetainedRecordings()

        XCTAssertFalse(CompactionDisk.exists(large), "control: the pass reached its delete step")
        XCTAssertTrue(CompactionDisk.exists(mix), "a size pass deleted the WAV in the middle of its commit")
        XCTAssertTrue(CompactionDisk.exists(flac), "a size pass deleted the copy the compactor just named")
        XCTAssertNil(settings.recordingStorageAlarm.load(), "under the limit once the large recording is gone")
        XCTAssertEqual(
            settings.recordingStorageStatus?.totalBytes, try fileSize(flac), "the WAV in mid-unlink was counted",
        )

        release.signal()
        await waitFor(
            !controller.recordingCompaction.isRunning && controller.recordingCompaction.awaitingCount == 0,
            timeout: .seconds(10),
        )
        XCTAssertTrue(KeptRecordingCompressor.isNativeFLAC(flac))
        XCTAssertFalse(CompactionDisk.exists(mix))
        let names = CompactionDisk.recordingNames(in: mix.deletingLastPathComponent())
        XCTAssertEqual(names, [flac.lastPathComponent], "only the FLAC is left, no partial")
        let listedAfter = controller.recordingRetention.registry.entries.flatMap(\.paths).map(\.lastPathComponent)
        XCTAssertEqual(listedAfter, [flac.lastPathComponent])
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        try Int64(XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int))
    }

    /// A marked entry left with both its WAV and its FLAC (a failed unlink, a
    /// quit before it) counts the pair once while the compactor takes marked
    /// entries, and both files once it does not: then no run removes the
    /// WAV, and leaving it out would let the recordings outgrow the limit.
    func testAMarkedPairCountsOnceOnlyWhileTheCompactorTakesMarkedEntries() async throws {
        enableTheStorageLimit()
        // The probe answers unknown, so the launch run converts nothing.
        let controller = try makeController(activate: false, probe: .unknown)
        let (mix, flac) = try registerMarkedPair(in: controller)
        controller.activate { MockEngine() }
        await controller.compactionLaunch?.value
        XCTAssertTrue(CompactionDisk.exists(mix) && CompactionDisk.exists(flac), "test premise: the launch run did nothing")

        controller.recordingCompaction.codecStatus = .available
        await controller.sweepRetainedRecordings()
        XCTAssertEqual(settings.recordingStorageStatus?.totalBytes, try fileSize(flac), "the WAV a run removes was counted")

        controller.recordingCompaction.codecStatus = .unavailable(reason: "notNativeFLAC")
        await controller.sweepRetainedRecordings()
        XCTAssertEqual(
            settings.recordingStorageStatus?.totalBytes, try fileSize(flac) + fileSize(mix),
            "with no FLAC, a WAV no run will remove went uncounted",
        )

        controller.recordingCompaction.codecStatus = .available
        settings.compressKeptRecordings = false
        await controller.sweepRetainedRecordings()
        XCTAssertEqual(
            settings.recordingStorageStatus?.totalBytes, try fileSize(flac) + fileSize(mix),
            "with the setting off, a WAV no run will remove went uncounted",
        )
    }

    private func enableTheStorageLimit() {
        settings.compressKeptRecordings = true
        settings.recordingRetentionEnabled = false
        settings.recordingStorageLimitEnabled = true
        settings.recordingStorageLimitGB = 1
    }

    /// A marked recording whose mix is listed and on disk as WAV and as its
    /// FLAC, as a quit between the rename and the unlink leaves it. With
    /// `wavSize`, the WAV's size is then set to that many bytes (the FLAC stays).
    private func registerMarkedPair(
        in controller: PipelineController, stem: String = "20260101_0900_sync_ab12cd34",
        recordedAt: Date = Date(timeIntervalSince1970: 1_767_258_000), eligibleAt: Date = Date(), under root: URL? = nil,
        wavSize: UInt64 = 0,
    ) throws -> (mix: URL, flac: URL) {
        let mix = try registerMarkedRecording(
            in: controller, stem: stem, recordedAt: recordedAt, eligibleAt: eligibleAt, under: root,
        )
        let flac = try XCTUnwrap(KeptRecordingCompressor.compressedURL(for: mix))
        try KeptRecordingCompressor().prepare(source: mix, partial: flac)
        if wavSize > 0 {
            let handle = try FileHandle(forWritingTo: mix)
            try handle.truncate(atOffset: wavSize)
            try handle.close()
        }
        let registry = controller.recordingRetention.registry
        let entry = try XCTUnwrap(registry.entries.first { $0.paths.contains(mix) })
        registry.register(jobID: entry.jobID, paths: [flac], root: entry.root, recordedAt: entry.recordedAt)
        return (mix, flac)
    }

    /// The first pass after a launch runs before the probe answers, and it
    /// is the pass that meets a pair a quit left. It counts that pair once,
    /// so a warning past its grace period deletes what the FLAC total needs
    /// and not a recording more for the WAV the launch run removes.
    func testTheLaunchPassBeforeTheProbeAnswersCountsALeftPairOnce() async throws {
        enableTheStorageLimit()
        let probeHeld = DispatchSemaphore(value: 0)
        defer { probeHeld.signal() }
        let controller = try makeController(activate: false, probeHeld: probeHeld)
        let twoDaysAgo = Date().addingTimeInterval(-48 * 3600)
        let oldest = try registerMarkedRecording(
            in: controller, stem: "20260101_0900_old_ab12cd34", recordedAt: Date(timeIntervalSince1970: 1_767_258_000),
            eligibleAt: twoDaysAgo, marked: false,
        )
        let older = try registerMarkedRecording(
            in: controller, stem: "20260102_0900_large_cd34ab12", recordedAt: Date(timeIntervalSince1970: 1_767_344_400),
            eligibleAt: twoDaysAgo, marked: false,
        )
        let (mix, flac) = try registerMarkedPair(
            in: controller, recordedAt: Date(timeIntervalSince1970: 1_767_430_800), eligibleAt: twoDaysAgo,
        )
        // Sized so the FLAC total fits once the oldest is gone and the total
        // with the WAV needs the older one gone too.
        let limit: Int64 = 1_000_000_000
        let olderSize = try limit - fileSize(flac) - fileSize(mix) / 2
        let handle = try FileHandle(forWritingTo: older)
        try handle.truncate(atOffset: UInt64(olderSize))
        try handle.close()
        settings.recordingStorageAlarm.save(RecordingStorageWarning(
            since: Date().addingTimeInterval(-25 * 3600), limitBytes: limit,
            root: RecordingRetentionPolicy.pathKey(settings.effectiveOutputDir),
        ))

        controller.activate { MockEngine() }
        await waitFor(settings.recordingStorageStatus != nil, timeout: .seconds(10))

        XCTAssertEqual(controller.recordingCompaction.codecStatus, .unknown, "test premise: the probe has not answered")
        XCTAssertFalse(CompactionDisk.exists(oldest), "control: the launch pass reached its delete step")
        XCTAssertTrue(CompactionDisk.exists(older), "the launch pass deleted a recording for a WAV the launch run removes")
        XCTAssertTrue(CompactionDisk.exists(mix) && CompactionDisk.exists(flac))
        XCTAssertEqual(settings.recordingStorageStatus?.totalBytes, try olderSize + fileSize(flac))
        probeHeld.signal()
        await controller.compactionLaunch?.value
    }

    /// With a built queue the folder the next run uses is the queue's: a pair
    /// under it counts once, a pair under the folder the settings name now
    /// (which the queue does not use until it is rebuilt) counts both.
    func testWithABuiltQueueThePairUnderItsFolderCountsOnce() async throws {
        enableTheStorageLimit()
        let queueRoot = tmpDir.appendingPathComponent("Queue", isDirectory: true)
        let controller = try makeController(activate: false, probe: .unknown, scopeOpens: false, queueRoot: queueRoot)
        // A WAV of another size, so the total tells which pair counted once.
        let underQueue = try registerMarkedPair(in: controller, under: queueRoot, wavSize: 100_000)
        let underSettings = try registerMarkedPair(in: controller)
        controller.activate { MockEngine() }
        await controller.compactionLaunch?.value
        controller.rebuild()
        XCTAssertNotNil(controller.queue.recordingCompaction, "test premise: a built queue")
        XCTAssertEqual(controller.queue.outputDir, queueRoot, "test premise")

        await controller.sweepRetainedRecordings()

        let expected = try fileSize(underQueue.flac) + fileSize(underSettings.flac) + fileSize(underSettings.mix)
        XCTAssertEqual(
            settings.recordingStorageStatus?.totalBytes, expected,
            "compared with the settings' folder instead of the built queue's",
        )
    }

    /// The compactor works only under the current output folder, so a
    /// marked pair under an earlier one waits for no run: with the compactor
    /// active it counts both files, while a pair under the current folder
    /// counts once. With no scope held on the output folder the pass counts
    /// every folder's entries, which is where the earlier one shows up.
    func testAMarkedPairUnderAnotherOutputFolderCountsBoth() async throws {
        enableTheStorageLimit()
        let controller = try makeController(activate: false, probe: .unknown, scopeOpens: false)
        let earlier = tmpDir.appendingPathComponent("Earlier", isDirectory: true)
        // WAVs of different sizes, so the total tells which pair counted once.
        let pairs = try [(nil, 0), (earlier, 100_000)].map { try registerMarkedPair(in: controller, under: $0.0, wavSize: $0.1) }
        controller.activate { MockEngine() }
        await controller.compactionLaunch?.value
        controller.recordingCompaction.codecStatus = .available

        await controller.sweepRetainedRecordings()

        let expected = try fileSize(pairs[0].flac) + fileSize(pairs[1].flac) + fileSize(pairs[1].mix)
        XCTAssertEqual(
            settings.recordingStorageStatus?.totalBytes, expected,
            "a WAV under a folder no run reaches went uncounted, or the current folder's counted twice",
        )
    }
}
