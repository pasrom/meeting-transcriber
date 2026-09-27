@testable import MeetingTranscriber
import XCTest

/// The queue `PipelineController` builds against the chosen output folder, and
/// what happens when the user picks another one.
///
/// A queue holds the security scope on the folder it was built with for its
/// whole lifetime (see `PipelineQueue`), so a queue that outlives a change of
/// folder keeps writing into the old one while Settings shows the new one.
/// These run the real `makeQueue()` against a temp log, staging and output
/// folder, with the staging recovery replaced by a counter because the real
/// one scans the real staging folder.
@MainActor
// swiftlint:disable:next attributes
final class PipelineControllerOutputFolderTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var suiteName: String!
    private var apiKeyAccount: String!
    private var claudeKeyAccount: String!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerOutputFolder")
        suiteName = "PipelineControllerOutputFolderTests-\(getpid())-\(UUID().uuidString)"
        apiKeyAccount = "\(suiteName ?? "")-openAI"
        claudeKeyAccount = "\(suiteName ?? "")-claude"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = AppSettings(
            defaults: defaults, apiKeyAccount: apiKeyAccount, claudeAPIKeyAccount: claudeKeyAccount,
            defaultOutputDir: tmpDir.appendingPathComponent("default-output", isDirectory: true),
        )
    }

    override func tearDown() async throws {
        settings = nil
        DefaultsSuite.remove(suiteName)
        KeychainHelper.delete(key: apiKeyAccount)
        KeychainHelper.delete(key: claudeKeyAccount)
        try await super.tearDown()
    }

    /// Start and stop calls, every URL the resolver handed out, and every queue
    /// the staging recovery ran for.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var startLog: [URL] = []
        private var stopLog: [URL] = []
        var resolved: [URL] = []
        var recoveries = 0

        var starts: [URL] {
            lock.withLock { startLog }
        }

        var stops: [URL] {
            lock.withLock { stopLog }
        }

        var access: SecurityScopeAccess {
            SecurityScopeAccess(
                start: { [self] url in lock.withLock { startLog.append(url) }
                    return true
                },
                stop: { [self] url in lock.withLock { stopLog.append(url) } },
            )
        }
    }

    private func makeController(_ recorder: Recorder) throws -> PipelineController {
        let staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        let logDir = tmpDir.appendingPathComponent("log", isDirectory: true)
        for dir in [staging, logDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let pc = PipelineController(
            settings: settings,
            notifier: RecordingNotifier(),
            terminalJobStore: TerminalJobStore(path: logDir.appendingPathComponent("terminal_jobs.json")),
            queueEnvironment: .init(
                logDir: logDir,
                stagingDir: staging,
                securityScope: recorder.access,
                recoverStagedRecordings: { _ in recorder.recoveries += 1 },
                resolveOutputDir: { resolver in
                    let url = resolver.resolve()
                    recorder.resolved.append(url)
                    return url
                },
            ),
        )
        pc.activate { MockEngine() }
        return pc
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func samePath(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Give the controller's observation a chance to run.
    private func settle(until condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The scope is opened on what the resolver returned

    /// Through the production wiring: the queue opens its scope on the very URL
    /// object the resolver returned from the bookmark, not on one equal to it.
    func testTheControllersQueueOpensTheScopeOnTheResolvedURLObject() throws {
        let chosen = try makeFolder("chosen")
        settings.setCustomOutputDir(chosen)
        let recorder = Recorder()
        let pc = try makeController(recorder)

        pc.ensureQueue()

        XCTAssertEqual(recorder.resolved.count, 1, "test premise: one queue, one resolution")
        XCTAssertEqual(recorder.starts.count, 1)
        let resolved = try XCTUnwrap(recorder.resolved.first)
        let started = try XCTUnwrap(recorder.starts.first)
        XCTAssertIdentical(
            started as AnyObject, resolved as AnyObject,
            "the scope was opened on a different URL object than the resolver returned",
        )
        XCTAssertTrue(samePath(pc.queue.outputDir, chosen), "test premise: the queue writes into the chosen folder")
    }

    // MARK: - A change of folder rebuilds the queue

    func testChangingTheFolderWhileIdleRebuildsTheQueueOnTheNewFolder() async throws {
        let first = try makeFolder("first")
        let second = try makeFolder("second")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        let pc = try makeController(recorder)
        pc.ensureQueue()
        weak let oldQueue = pc.queue
        var replacedWith: PipelineQueue?
        pc.onQueueReplaced = { replacedWith = $0 }

        settings.setCustomOutputDir(second)
        await settle { samePath(pc.queue.outputDir, second) }

        XCTAssertTrue(samePath(pc.queue.outputDir, second), "the queue still writes into the old folder")
        XCTAssertIdentical(replacedWith, pc.queue, "the holder of the old queue was not told")
        await settle { oldQueue == nil }
        XCTAssertNil(oldQueue, "test premise: the old queue went away")
        XCTAssertEqual(recorder.stops.count, 1, "the old folder's scope was not released")
        XCTAssertTrue(samePath(recorder.stops.first, first))
    }

    func testChangingTheFolderWhileAJobRunsWaitsForItThenRebuilds() async throws {
        let first = try makeFolder("first")
        let second = try makeFolder("second")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        let pc = try makeController(recorder)
        pc.ensureQueue()
        let busyQueue = pc.queue
        let jobID = busyQueue.insertJobForTesting(
            mixPath: tmpDir.appendingPathComponent("busy.wav"), state: .generatingProtocol,
        )

        settings.setCustomOutputDir(second)
        await settle { false }
        XCTAssertIdentical(pc.queue, busyQueue, "the queue was replaced under an unfinished job")

        busyQueue.updateJobState(id: jobID, to: .done)
        await settle { pc.queue !== busyQueue }
        XCTAssertTrue(samePath(pc.queue.outputDir, second), "the deferred rebuild never happened")
    }

    /// A queue the controller did not build (a test injects one through
    /// `queue`) is not the controller's to replace. Replacing it would swap in a
    /// queue with the production engine, logs and snapshot, which is what the
    /// injection was there to keep out.
    func testAFolderChangeLeavesAnInjectedQueueAlone() async throws {
        let first = try makeFolder("first")
        let second = try makeFolder("second")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        let pc = try makeController(recorder)
        let injected = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: first,
            logDir: tmpDir.appendingPathComponent("log", isDirectory: true),
        )
        pc.queue = injected

        settings.setCustomOutputDir(second)
        await settle { pc.queue !== injected }

        XCTAssertIdentical(pc.queue, injected, "the controller replaced a queue it did not build")
        XCTAssertTrue(recorder.resolved.isEmpty, "a queue was built from the production wiring")
    }

    /// The staging recovery repairs, re-mixes and deletes files in the folder
    /// the recorder writes to, guarded only by how recently a file was written.
    /// A launch or a watch start runs it with nothing recording; a folder
    /// change can come mid-recording, where a track that has not been written
    /// for half a minute would be taken for a crashed one.
    func testAFolderChangeRebuildDoesNotRerunTheStagingRecovery() async throws {
        let first = try makeFolder("first")
        let second = try makeFolder("second")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        let pc = try makeController(recorder)
        pc.ensureQueue()
        XCTAssertEqual(recorder.recoveries, 1, "test premise: the first queue recovers the staging folder")

        settings.setCustomOutputDir(second)
        await settle { samePath(pc.queue.outputDir, second) }

        XCTAssertTrue(samePath(pc.queue.outputDir, second), "test premise: the queue was rebuilt")
        XCTAssertEqual(recorder.recoveries, 1, "the folder change ran the staging recovery again")
    }

    /// An active watch loop holds the queue it was built with, and enqueues
    /// every recording it finishes there. It has to follow a rebuild.
    func testAnActiveWatchLoopFollowsTheRebuiltQueue() async throws {
        let first = try makeFolder("first")
        let second = try makeFolder("second")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        let pc = try makeController(recorder)
        pc.ensureQueue()
        let notifier = RecordingNotifier()
        let watching = WatchingController(
            settings: settings,
            notifier: notifier,
            pipeline: pc,
            channelHealth: ChannelHealthController(notifier: notifier, debounceSeconds: { 0 }, indicatorEnabled: { false }),
            permissions: PermissionsController(notifier: notifier),
            liveTranscription: LiveTranscriptionCoordinator(
                captions: LiveCaptionsState(),
                liveEnabled: { false },
                engineSupportsLive: { false },
                verboseDiagnostics: { false },
            ),
            ensureMicAccess: { true },
            makeDetector: { makeSilentDetector() },
            makeRecorder: { makeMockRecorder() },
        )
        let loop = WatchLoop(detector: makeSilentDetector(), recorderFactory: { makeMockRecorder() }, pipelineQueue: pc.queue)
        watching.watchLoop = loop

        settings.setCustomOutputDir(second)
        await settle { samePath(pc.queue.outputDir, second) }

        XCTAssertTrue(samePath(pc.queue.outputDir, second), "test premise: the queue was rebuilt")
        XCTAssertIdentical(loop.pipelineQueue, pc.queue, "the watch loop still enqueues into the old queue")
    }

    // MARK: - The rebuild must not re-read a snapshot that is still being written

    /// A folder change is triggered by the very job transition whose snapshot
    /// write is still in flight, so the file on disk can still show the job as
    /// running while memory already has it finished. Re-reading the file then
    /// restores a finished job as `.waiting` and runs it a second time: a second
    /// protocol generation over the same transcript, an overwritten `.md`, and a
    /// second "ready" notification. Without a protocol provider it is worse, the
    /// job is transcribed and diarized again and asks for speaker names twice.
    ///
    /// Disk and memory are given deliberately different states here instead of
    /// racing the writer, so what this pins is which source the rebuild reads,
    /// not a timing window. The job is gone afterwards either way, because a
    /// finished job is dropped on adoption as it is on restore; what separates
    /// the two sources is that reading the file would bring it back as live
    /// work.
    func testTheFolderChangeRebuildIgnoresAStaleSnapshotFile() async throws {
        let first = try makeFolder("first")
        let second = try makeFolder("second")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        let pc = try makeController(recorder)
        pc.ensureQueue()
        let replaced = pc.queue

        // A finished job whose audio and transcript are both still on disk, so
        // the restore path would keep it rather than discard it as incomplete.
        let mix = tmpDir.appendingPathComponent("finished.wav")
        try Data("audio".utf8).write(to: mix)
        let transcript = first.appendingPathComponent("finished.txt")
        try Data("transcript".utf8).write(to: transcript)
        var job = PipelineJob(
            meetingTitle: "Finished", appName: "Teams",
            mixPath: mix, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.transcriptPath = transcript
        job.state = .done
        replaced.insertJobForTesting(job)

        // What a snapshot write that has not landed yet leaves on disk: the
        // state before the job finished.
        var stale = job
        stale.state = .generatingProtocol
        try PipelineSnapshot.save([stale], to: tmpDir.appendingPathComponent("log", isDirectory: true))

        settings.setCustomOutputDir(second)
        await settle { pc.queue !== replaced }

        XCTAssertTrue(samePath(pc.queue.outputDir, second), "the rebuild never happened")
        XCTAssertTrue(
            pc.queue.jobs.isEmpty,
            "the rebuilt queue took its job from the stale file instead of the queue it replaced, so a "
                + "finished job is queued again and its protocol regenerated over the same transcript",
        )
    }

    /// `makeQueue()` is also called for its return value alone, by tests and by
    /// anything that wants a configured queue without installing it. It used to
    /// record "this is the queue I built, from this bookmark" itself, so such a
    /// call left the record pointing at a throwaway that died immediately. The
    /// folder-change rebuild then never fired again for the rest of the session,
    /// while the bookmark it compares against had already advanced: a silent
    /// stop, with every job after it landing in the old folder.
    func testAQueueBuiltWithoutBeingInstalledDoesNotDisarmTheFolderChange() async throws {
        let first = try makeFolder("first")
        let second = try makeFolder("second")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        let pc = try makeController(recorder)
        pc.ensureQueue()
        let installed = pc.queue

        _ = pc.makeQueue()

        settings.setCustomOutputDir(second)
        await settle { pc.queue !== installed }

        XCTAssertTrue(
            samePath(pc.queue.outputDir, second),
            "building a queue without installing it switched the folder change off",
        )
    }

    // MARK: - What the rebuild takes over, and what it drops

    /// The rebuild adopts from memory, so it has to drop a finished job exactly
    /// as the snapshot restore does. Keeping it looked harmless and was not: the
    /// 60-second reaper that removes a `.done` job is a task owned by the queue
    /// the job came from, so an adopted one keeps no reaper at all. It would sit
    /// in the list and in the snapshot forever, its 16 kHz sidecars would stay in
    /// the folder the user just navigated away from, and opening it from the menu
    /// would reach into a folder whose security scope died with the old queue.
    func testTheRebuildDropsAFinishedJobAsTheSnapshotRestoreDoes() async throws {
        let first = try makeFolder("first")
        let second = try makeFolder("second")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        let pc = try makeController(recorder)
        pc.ensureQueue()
        let replaced = pc.queue

        let mix = tmpDir.appendingPathComponent("finished.wav")
        try Data("audio".utf8).write(to: mix)
        var job = PipelineJob(
            meetingTitle: "Finished", appName: "Teams",
            mixPath: mix, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .done
        replaced.insertJobForTesting(job)

        settings.setCustomOutputDir(second)
        await settle { pc.queue !== replaced }

        XCTAssertTrue(pc.queue.jobs.isEmpty, "the finished job survived the rebuild and now has no reaper")
    }

    /// A failed job is kept, because the snapshot restore keeps it: the user can
    /// still retry it, and the retry is what cleans up after it.
    func testTheRebuildKeepsAFailedJob() async throws {
        let first = try makeFolder("first")
        let second = try makeFolder("second")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        let pc = try makeController(recorder)
        pc.ensureQueue()
        let replaced = pc.queue

        let mix = tmpDir.appendingPathComponent("failed.wav")
        try Data("audio".utf8).write(to: mix)
        var job = PipelineJob(
            meetingTitle: "Failed", appName: "Teams",
            mixPath: mix, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .error
        job.error = "transcription failed"
        replaced.insertJobForTesting(job)

        settings.setCustomOutputDir(second)
        await settle { pc.queue !== replaced }

        XCTAssertEqual(pc.queue.jobs.map(\.state), [.error], "the failed job was dropped, so it cannot be retried")
    }

    /// The very first queue has to read the snapshot: it is how a job that was
    /// interrupted by a crash or a quit comes back. Only a queue this controller
    /// already built carries the current state in memory, and only that one may
    /// be adopted from. Getting this backwards would silently retire crash
    /// recovery while every other test stayed green.
    func testTheFirstQueueStillReadsTheSnapshot() throws {
        let first = try makeFolder("first")
        settings.setCustomOutputDir(first)
        let recorder = Recorder()
        // Built first: it creates the log folder the snapshot is written into.
        // `activate` alone builds no queue, `ensureQueue()` below does.
        let pc = try makeController(recorder)

        let mix = tmpDir.appendingPathComponent("interrupted.wav")
        try Data("audio".utf8).write(to: mix)
        var job = PipelineJob(
            meetingTitle: "Interrupted", appName: "Teams",
            mixPath: mix, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .error
        try PipelineSnapshot.save([job], to: tmpDir.appendingPathComponent("log", isDirectory: true))

        pc.ensureQueue()

        XCTAssertEqual(
            pc.queue.jobs.map(\.state), [.error],
            "the first queue did not read the snapshot, so an interrupted job is lost on restart",
        )
    }
}
