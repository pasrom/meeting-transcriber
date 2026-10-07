@testable import MeetingTranscriber
import XCTest

/// A queue `rebuild()` replaced writes nothing more to the snapshot file.
///
/// One writer per file orders the writes by when they were saved, so a save
/// from the replaced queue that is made after the replacement wins over the
/// active queue's state: the replaced queue holds the list it had at the
/// swap, and saving it puts that list back on disk. Work that outlives the
/// swap does exactly that: the staging recovery a queue starts when it is
/// built holds that queue until its scan returns, then enqueues what it found
/// and saves.
@MainActor
final class PipelineQueueRetirementTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineQueueRetirementTests")
        let suite = "PipelineQueueRetirementTests-\(getpid())-\(UUID().uuidString)"
        settings = try AppSettings(
            defaults: XCTUnwrap(UserDefaults(suiteName: suite)),
            defaultOutputDir: tmpDir.appendingPathComponent("output", isDirectory: true),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// A controller that has built a queue itself and then replaced it, so
    /// the second build adopts from the first as production does.
    private func makeControllerAfterAReplacement() -> (PipelineController, replaced: PipelineQueue) {
        let controller = PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir),
        )
        controller.activate { MockEngine() }
        controller.rebuild()
        let replaced = controller.queue
        controller.rebuild()
        XCTAssertNotIdentical(controller.queue, replaced, "test premise: the second rebuild replaced the queue")
        return (controller, replaced)
    }

    private func makeFailedJob(title: String) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: title, appName: "Microsoft Teams",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .error
        return job
    }

    func testASaveFromTheReplacedQueueAfterTheReplacementDoesNotOverwriteTheActiveState() async throws {
        let (controller, replaced) = makeControllerAfterAReplacement()
        let active = makeFailedJob(title: "Imported After The Rebuild")
        controller.queue.insertJobForTesting(active)
        controller.queue.saveSnapshot()

        // What the replaced queue's late work does: change its own list, save.
        replaced.insertJobForTesting(makeFailedJob(title: "Late Work On The Replaced Queue"))
        replaced.saveSnapshot()
        await controller.queue.awaitSnapshotFlush()

        let onDisk = try XCTUnwrap(try PipelineSnapshot.load(from: tmpDir))
        XCTAssertEqual(
            onDisk.map(\.meetingTitle), [active.meetingTitle],
            "the replaced queue's save put its stale list over the active queue's",
        )
    }

    /// The recovery the replaced queue started finds an orphan only after the
    /// swap. The active queue's own recovery finds the same file, so taking
    /// it on the replaced queue as well would process it twice, once on a
    /// queue nobody sees.
    func testTheReplacedQueuesRecoveryEnqueuesNothingAfterTheReplacement() async throws {
        let (controller, replaced) = makeControllerAfterAReplacement()
        let staging = try makeTempDirectory(prefix: "retired_recovery")
        try AudioMixer.saveWAV(
            samples: [Float](repeating: 0.1, count: 1600), sampleRate: 16000,
            url: staging.appendingPathComponent("20260311_140000_mix.wav"),
        )

        await replaced.recoverOrphanedRecordings(recordingsDir: staging)
        await controller.queue.awaitSnapshotFlush()

        XCTAssertEqual(replaced.jobs.count, 0, "the replaced queue took on an orphan after the replacement")
        XCTAssertEqual(try ((PipelineSnapshot.load(from: tmpDir)) ?? []).count, 0, "the replaced queue saved after the replacement")
    }

    /// A folder-change rebuild runs no staging recovery (a recording may be
    /// running), so an orphan the replaced queue's recovery found after the
    /// swap is taken by nobody right away. It stays in staging, not marked as
    /// processed, for the next recovery, which a watch start or the next
    /// launch runs.
    func testAfterAFolderChangeRebuildAnOrphanWaitsInStagingForTheNextRecovery() async throws {
        let controller = PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir),
        )
        controller.activate { MockEngine() }
        controller.rebuild()
        let replaced = controller.queue
        controller.rebuild(recoversStagedRecordings: false)
        XCTAssertNotIdentical(controller.queue, replaced, "test premise: the folder-change rebuild replaced the queue")
        let staging = try makeTempDirectory(prefix: "retired_folder_change")
        let orphan = staging.appendingPathComponent("20260311_140000_mix.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: 1600), sampleRate: 16000, url: orphan)

        await replaced.recoverOrphanedRecordings(recordingsDir: staging)

        XCTAssertEqual(replaced.jobs.count + controller.queue.jobs.count, 0, "test premise: nobody took the orphan yet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        // The next recovery on the active queue.
        await controller.queue.recoverOrphanedRecordings(recordingsDir: staging)

        XCTAssertEqual(controller.queue.jobs.compactMap(\.mixPath?.lastPathComponent), [orphan.lastPathComponent])
    }
}
