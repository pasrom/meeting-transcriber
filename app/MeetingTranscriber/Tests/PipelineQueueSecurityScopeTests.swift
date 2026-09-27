@testable import MeetingTranscriber
import XCTest

/// Where and when the pipeline holds security-scoped access to the output folder.
///
/// The rule is on `SecurityScopeAccess`. The unsandboxed test process cannot
/// observe a sandbox denial, so these tests pin the shape through the injected
/// `SecurityScopeAccess`:
///
/// - every scope is opened on the very URL object the queue was built with,
///   compared by identity of the bridged `NSURL`, because `==` also holds for a
///   URL rebuilt from the same path (pinned by the first test);
/// - no file under the output folder is created or modified while no scope on
///   the root is open (by inode, size and modification date, so an overwrite
///   counts as much as a new file);
/// - operations that only read (a restore, a naming confirm) run while it is open.
///
/// Reads cannot be observed from here. They are covered because the scope is
/// held for the queue's whole lifetime, which the tests also pin.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class PipelineQueueSecurityScopeTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "pipeline_security_scope_test")
    }

    // MARK: - Recorder

    private struct FileState: Equatable {
        let inode: Int
        let size: Int
        let modified: Date
    }

    /// Records scope events against one root and which files changed while no
    /// scope on it was open.
    private final class ScopeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        let root: URL
        private var depth = 0
        private var stateAtLastClose: [String: FileState]
        // Written from `start`/`stop`, and `stop` runs in the queue's deinit,
        // which may be off the main actor; every access goes through `lock`.
        private var startLog: [URL] = []
        private var stopLog: [URL] = []
        private var changedWhileClosed: Set<String> = []
        private var closedMarks: [String] = []

        var starts: [URL] {
            lock.withLock { startLog }
        }

        var stops: [URL] {
            lock.withLock { stopLog }
        }

        var marksWhileClosed: [String] {
            lock.withLock { closedMarks }
        }

        init(root: URL) {
            self.root = root
            stateAtLastClose = Self.state(under: root)
        }

        var access: SecurityScopeAccess {
            SecurityScopeAccess(
                start: { [self] url in
                    lock.withLock {
                        startLog.append(url)
                        guard isRoot(url) else { return }
                        if depth == 0 { collectChangesSinceLastClose() }
                        depth += 1
                    }
                    return true
                },
                stop: { [self] url in
                    lock.withLock {
                        stopLog.append(url)
                        guard isRoot(url) else { return }
                        depth -= 1
                        if depth == 0 { stateAtLastClose = Self.state(under: root) }
                    }
                },
            )
        }

        /// The URL object this recorder watches, not merely its path: the
        /// bridged Foundation objects are compared by identity.
        func isRoot(_ url: URL) -> Bool {
            (url as AnyObject) === (root as AnyObject)
        }

        /// Note that `operation` is about to touch the output folder.
        func mark(_ operation: String) {
            lock.withLock { if depth == 0 { closedMarks.append(operation) } }
        }

        var isOpen: Bool {
            lock.withLock { depth > 0 }
        }

        /// Close the books: anything changed since the last close was also
        /// changed without a scope.
        func finish() -> Set<String> {
            lock.withLock {
                if depth == 0 { collectChangesSinceLastClose() }
                return changedWhileClosed
            }
        }

        private func collectChangesSinceLastClose() {
            let now = Self.state(under: root)
            for (path, state) in now where stateAtLastClose[path] != state {
                changedWhileClosed.insert(path)
            }
        }

        static func state(under root: URL) -> [String: FileState] {
            let fm = FileManager.default
            var result: [String: FileState] = [:]
            let enumerator = fm.enumerator(atPath: root.path)
            while let path = enumerator?.nextObject() as? String {
                guard let attrs = try? fm.attributesOfItem(atPath: root.appendingPathComponent(path).path),
                      attrs[.type] as? FileAttributeType == .typeRegular
                else { continue }
                result[path] = FileState(
                    inode: (attrs[.systemFileNumber] as? Int) ?? -1,
                    size: (attrs[.size] as? Int) ?? -1,
                    modified: (attrs[.modificationDate] as? Date) ?? .distantPast,
                )
            }
            return result
        }
    }

    /// A protocol generator that parks inside `generate` until released, so a
    /// test can act while a job is mid-run.
    private final class GatedProtocolGen: ProtocolGenerating, @unchecked Sendable {
        private let lock = NSLock()
        private var entered: CheckedContinuation<Void, Never>?
        private var hasEntered = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var released = false

        func generate(transcript _: String, title _: String, diarized _: Bool, meetingStartTime _: Date?) async -> String {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                hasEntered = true
                defer { entered = nil }
                return entered
            }
            waiter?.resume()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if released { return true }
                    releaseContinuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            return "# Protocol"
        }

        func waitUntilEntered() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if hasEntered { return true }
                    entered = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func release() {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                released = true
                defer { releaseContinuation = nil }
                return releaseContinuation
            }
            waiter?.resume()
        }
    }

    // MARK: - Fixtures

    /// The output folder. Stands in for the URL the bookmark resolved to; the
    /// recorder compares every scope against this object.
    private func makeRoot() throws -> URL {
        let root = tmpDir.appendingPathComponent("picked", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStaging() throws -> URL {
        let staging = tmpDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private func makeQueue(
        _ recorder: ScopeRecorder, staging: URL,
        diarization: MockDiarization? = nil,
        protocolGen: any ProtocolGenerating = MockProtocolGen(),
        engine: MockEngine? = nil,
    ) -> PipelineQueue {
        let engine = engine ?? {
            let e = MockEngine()
            e.segmentsToReturn = [TimestampedSegment(start: 0, end: 5, text: "Scoped words")]
            return e
        }()
        return PipelineQueue(
            engine: engine,
            diarizationFactory: { diarization ?? MockDiarization() },
            diarizationFactoryWithMode: { _ in diarization ?? MockDiarization() },
            protocolGeneratorFactory: { protocolGen },
            outputDir: recorder.root,
            logDir: tmpDir,
            stagingDir: staging,
            diarizeEnabled: diarization != nil,
            micLabel: "Me",
            inFlightRuns: InFlightRunRegistry(),
            securityScope: recorder.access,
        )
    }

    /// A diarizer whose result carries embeddings, so the job parks for naming.
    private func namingDiarization() -> MockDiarization {
        let diar = MockDiarization()
        diar.resultToReturn = DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakingTimes: ["SPEAKER_0": 5],
            autoNames: [:],
            embeddings: ["SPEAKER_0": [1, 0, 0]],
        )
        return diar
    }

    /// A dual-source job whose three tracks sit in the staging folder, so
    /// stage 3 relocates all of them into `recordings/`.
    private func makeDualSourceJob(in staging: URL, title: String) throws -> PipelineJob {
        let mix = try createTestAudioFile(in: staging)
        let app = staging.appendingPathComponent("\(UUID().uuidString)_app.wav")
        let mic = staging.appendingPathComponent("\(UUID().uuidString)_mic.wav")
        try FileManager.default.copyItem(at: mix, to: app)
        try FileManager.default.copyItem(at: mix, to: mic)
        return PipelineJob(
            meetingTitle: title, appName: "Teams",
            mixPath: mix, appPath: app, micPath: mic, micDelay: 0,
        )
    }

    private func waitForState(
        _ queue: PipelineQueue, jobID: UUID, _ state: JobState, _ run: () async -> Void,
    ) async {
        let reached = expectation(description: "job reached \(state)")
        reached.assertForOverFulfill = false
        queue.onJobStateChange = { job, _, new in
            if job.id == jobID, new == state { reached.fulfill() }
        }
        await run()
        await fulfillment(of: [reached], timeout: 10)
        queue.onJobStateChange = nil
    }

    /// Drop a queue and wait until its deinit has run.
    private func release(_ queue: inout PipelineQueue?) async {
        await queue?.awaitProcessing()
        await queue?.awaitSnapshotFlush()
        weak let weakQueue = queue
        queue = nil
        for _ in 0 ..< 200 where weakQueue != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(weakQueue, "test premise: the queue was released")
    }

    private func assertScopeDiscipline(
        _ recorder: ScopeRecorder, queues: Int,
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        for url in recorder.starts + recorder.stops {
            XCTAssertTrue(
                recorder.isRoot(url),
                "scope opened or closed on a URL object other than the one the queue was built with: \(url)",
                file: file, line: line,
            )
        }
        XCTAssertEqual(recorder.starts.count, queues, "one scope per queue, held for its lifetime", file: file, line: line)
        XCTAssertEqual(recorder.stops.count, queues, "each queue closes its scope exactly once", file: file, line: line)
        XCTAssertEqual(recorder.marksWhileClosed, [], "ran with no scope open", file: file, line: line)
        let changed = recorder.finish()
        XCTAssertTrue(changed.isEmpty, "changed while no scope on the root was open: \(changed.sorted())", file: file, line: line)
    }

    private func files(under root: URL) -> [String] {
        ScopeRecorder.state(under: root).keys.sorted()
    }

    // MARK: - Tests

    /// Why the recorder compares objects: a URL rebuilt from the root's path is
    /// `==` to it, and carries no scope in the sandboxed build.
    func testARebuiltURLIsEqualButNotTheSameObject() throws {
        let root = try makeRoot()
        let rebuilt = URL(fileURLWithPath: root.path, isDirectory: true)
        XCTAssertEqual(rebuilt, root, "premise: == cannot tell them apart")
        XCTAssertFalse(ScopeRecorder(root: root).isRoot(rebuilt))
        XCTAssertTrue(ScopeRecorder(root: root).isRoot(root))
    }

    /// Dropping the last outside reference while a job runs must not close the
    /// scope underneath it: the processing task holds the queue until the job
    /// returns, and only then does `deinit` close it.
    func testDroppingTheQueueMidJobKeepsTheScopeUntilTheJobEnds() async throws {
        let root = try makeRoot()
        let staging = try makeStaging()
        let recorder = ScopeRecorder(root: root)
        let gate = GatedProtocolGen()
        var queue: PipelineQueue? = makeQueue(recorder, staging: staging, protocolGen: gate)
        weak let weakQueue = queue
        let job = try PipelineJob(
            meetingTitle: "Dropped Mid Job", appName: "Teams",
            mixPath: createTestAudioFile(in: staging), appPath: nil, micPath: nil, micDelay: 0,
        )
        queue?.enqueue(job)
        await gate.waitUntilEntered()
        queue = nil

        XCTAssertNotNil(weakQueue, "the running job keeps its queue alive")
        XCTAssertEqual(recorder.stops.count, 0, "the scope was closed while the job was still running")
        XCTAssertTrue(recorder.isOpen)

        gate.release()
        for _ in 0 ..< 500 where weakQueue != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(weakQueue, "test premise: the queue went away once the job ended")
        let written = files(under: root)
        XCTAssertTrue(written.contains { $0.hasPrefix("protocols/") && $0.hasSuffix(".md") }, "\(written)")
        assertScopeDiscipline(recorder, queues: 1)
    }

    /// Single source, no diarization: the transcript draft, its overwrite by
    /// stage 3, the relocated audio, the 16 kHz sidecar and the protocol.
    func testAStraightThroughJobWritesOnlyWhileTheRootScopeIsOpen() async throws {
        let root = try makeRoot()
        let staging = try makeStaging()
        let recorder = ScopeRecorder(root: root)
        var queue: PipelineQueue? = makeQueue(recorder, staging: staging)

        let job = try PipelineJob(
            meetingTitle: "Scoped Call", appName: "Teams",
            mixPath: createTestAudioFile(in: staging), appPath: nil, micPath: nil, micDelay: 0,
        )
        queue?.insertJobForTesting(job)
        recorder.mark("processNext")
        await queue?.processNext()
        XCTAssertEqual(queue?.jobs.first?.state, .done, "test premise: the job ran to completion")
        await release(&queue)

        let written = files(under: root)
        XCTAssertTrue(written.contains { $0.hasPrefix("protocols/") && $0.hasSuffix(".txt") }, "\(written)")
        XCTAssertTrue(written.contains { $0.hasPrefix("protocols/") && $0.hasSuffix(".md") }, "\(written)")
        XCTAssertTrue(written.contains { $0.hasSuffix("_mix.wav") }, "\(written)")
        XCTAssertTrue(written.contains { $0.hasSuffix("_16k.wav") }, "\(written)")
        assertScopeDiscipline(recorder, queues: 1)
    }

    /// Dual source with diarization: the naming sidecar, a late re-run that
    /// reads the persisted 16 kHz tracks, then a confirm that rewrites the
    /// transcript and saves the protocol.
    func testDualSourceNamingRerunAndConfirmStayInsideTheRootScope() async throws {
        let root = try makeRoot()
        let staging = try makeStaging()
        let recorder = ScopeRecorder(root: root)
        let diar = namingDiarization()
        var queue: PipelineQueue? = makeQueue(recorder, staging: staging, diarization: diar)
        do {
            let q = try XCTUnwrap(queue)

            let job = try makeDualSourceJob(in: staging, title: "Dual Scoped")
            q.enqueue(job)
            recorder.mark("processNext")
            await waitForState(q, jobID: job.id, .speakerNamingPending) { await q.processNext() }
            XCTAssertTrue(files(under: root).contains { $0.hasSuffix("_naming.json") }, "test premise: naming data saved")

            recorder.mark("rerun")
            await waitForState(q, jobID: job.id, .speakerNamingPending) {
                q.completeSpeakerNaming(jobID: job.id, result: .rerun(2), source: .dialog)
            }
            XCTAssertGreaterThanOrEqual(diar.runCount, 2, "test premise: the re-run diarized again")

            let label = try XCTUnwrap(q.naming.speakerNamingDataByJob[job.id]?.mapping.keys.min())
            recorder.mark("confirm")
            await waitForState(q, jobID: job.id, .done) {
                q.completeSpeakerNaming(jobID: job.id, result: .confirmed([label: "Speaker A"]), source: .dialog)
            }
            let txt = try XCTUnwrap(q.jobs.first { $0.id == job.id }?.transcriptPath)
            XCTAssertTrue(try String(contentsOf: txt, encoding: .utf8).contains("Speaker A"), "test premise: rewrite happened")
            XCTAssertNotNil(q.jobs.first { $0.id == job.id }?.protocolPath)
        }
        await release(&queue)
        assertScopeDiscipline(recorder, queues: 1)
    }

    /// A relaunch: the second queue restores a job parked for naming (reading
    /// the naming sidecar) and confirms it. The restore must run under the new
    /// queue's own scope, since the first one's is gone.
    func testARestoreAfterRelaunchReadsAndWritesUnderTheNewQueuesScope() async throws {
        let root = try makeRoot()
        let staging = try makeStaging()
        let recorder = ScopeRecorder(root: root)
        let job = try makeDualSourceJob(in: staging, title: "Relaunch Scoped")

        var first: PipelineQueue? = makeQueue(recorder, staging: staging, diarization: namingDiarization())
        do {
            let q1 = try XCTUnwrap(first)
            q1.enqueue(job)
            await waitForState(q1, jobID: job.id, .speakerNamingPending) { await q1.processNext() }
        }
        await release(&first)
        XCTAssertFalse(recorder.isOpen, "test premise: the first queue's scope is closed, as after a quit")

        var second: PipelineQueue? = makeQueue(recorder, staging: staging, diarization: namingDiarization())
        do {
            let q2 = try XCTUnwrap(second)
            recorder.mark("loadSnapshot")
            q2.loadSnapshot()
            XCTAssertEqual(q2.jobs.first?.state, .speakerNamingPending, "test premise: restored from the naming sidecar")

            let label = try XCTUnwrap(q2.naming.speakerNamingDataByJob[job.id]?.mapping.keys.min())
            recorder.mark("confirm")
            await waitForState(q2, jobID: job.id, .done) {
                q2.completeSpeakerNaming(jobID: job.id, result: .confirmed([label: "Speaker B"]), source: .dialog)
            }
            XCTAssertNotNil(q2.jobs.first?.protocolPath)
        }
        await release(&second)
        assertScopeDiscipline(recorder, queues: 2)
    }

    /// A relaunch while the protocol was being generated: the restored queue
    /// reads the saved transcript and writes only the protocol.
    func testResumingProtocolGenerationAfterRelaunchStaysInsideTheScope() async throws {
        let root = try makeRoot()
        let staging = try makeStaging()
        let recorder = ScopeRecorder(root: root)
        let job = try makeDualSourceJob(in: staging, title: "Resume Scoped")

        var first: PipelineQueue? = makeQueue(recorder, staging: staging)
        var interrupted: PipelineJob
        do {
            let q1 = try XCTUnwrap(first)
            q1.enqueue(job)
            await q1.processNext()
            interrupted = try XCTUnwrap(q1.jobs.first { $0.id == job.id })
        }
        await release(&first)
        let mdPath = try XCTUnwrap(interrupted.protocolPath)
        interrupted.state = .generatingProtocol
        interrupted.protocolPath = nil
        // Stands in for the kill: the protocol never reached disk. A removal is
        // not a change the recorder counts, so doing it here with no scope open
        // does not taint the books.
        try FileManager.default.removeItem(at: mdPath)
        try JSONEncoder().encode([interrupted])
            .write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let engine = MockEngine()
        let protocolGen = MockProtocolGen()
        var second: PipelineQueue? = makeQueue(recorder, staging: staging, protocolGen: protocolGen, engine: engine)
        do {
            let q2 = try XCTUnwrap(second)
            recorder.mark("loadSnapshot")
            q2.loadSnapshot()
            await q2.awaitProcessing()
            XCTAssertEqual(engine.transcribeCallCount, 0, "test premise: resumed, not re-run")
            XCTAssertTrue(protocolGen.generateCalled)
            XCTAssertEqual(q2.jobs.first?.state, .done)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdPath.path))
        await release(&second)
        assertScopeDiscipline(recorder, queues: 2)
    }
}
