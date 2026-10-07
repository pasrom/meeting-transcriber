@testable import MeetingTranscriber
import XCTest

/// Who owns the queue snapshot file.
///
/// The jobs list and its snapshot live in a fixed `logDir` but hang off the
/// lifetime of a `PipelineQueue` instance. A rebuild therefore has two queues
/// over one file, each with its own serializing actor, and the mitigations for
/// that are a stack: a process-wide in-flight registry, `sidecarOutputDir` on
/// the job, `adoptJobs`, and `discardPendingSnapshot`.
///
/// These tests pin what that stack does and does not cover, so a change that
/// gives the file a single owner has something to be measured against.
@MainActor
final class SnapshotOwnershipTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var logDir: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotOwnershipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let logDir { try? FileManager.default.removeItem(at: logDir) }
        try await super.tearDown()
    }

    /// The mix file is created, because `adoptJobs` drops a job whose audio is
    /// gone and the point here is a job the replacement does keep.
    private func job(_ title: String, state: JobState) throws -> PipelineJob {
        let mix = logDir.appendingPathComponent("\(title).wav")
        try Data("RIFF".utf8).write(to: mix)
        var job = PipelineJob(
            meetingTitle: title, appName: "Test",
            mixPath: mix, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = state
        return job
    }

    private func snapshotOnDisk() throws -> [PipelineJob] {
        try XCTUnwrap(PipelineSnapshot.load(from: logDir), "no snapshot was written")
    }

    /// `discardPendingSnapshot` drops a write the replaced queue has not
    /// started. It cannot drop one already inside the writer, and that is the
    /// case the serializing actor exists for: `replaceItemAt` can stall for
    /// seconds on macOS 26, which is a window wide enough for the controller to
    /// build the replacement and move on.
    ///
    /// The stale write then lands last and the file describes the queue that
    /// went away. A restart restores from there, which is how a finished job
    /// gets queued a second time, the failure `adoptJobs` cites as issue #744.
    func testAStalledWriteOfTheReplacedQueueOutlivesTheDiscard() async throws {
        let writeStarted = expectation(description: "the replaced queue's write reached the writer")
        let writeFinished = expectation(description: "the replaced queue's write returned")
        let release = DispatchSemaphore(value: 0)

        // Named rather than passed as a literal: as a trailing closure the
        // formatter binds it to the init's last closure parameter instead of
        // `snapshotWriter`.
        let stalling: @Sendable ([PipelineJob], URL) throws -> Void = { jobs, dir in
            writeStarted.fulfill()
            release.wait()
            try PipelineSnapshot.save(jobs, to: dir)
            writeFinished.fulfill()
        }
        let replaced = PipelineQueue(logDir: logDir, snapshotWriter: stalling)
        try replaced.insertJobForTesting(job("stale", state: .transcribing))
        replaced.saveSnapshot()
        // Yields the main actor so the worker can take the batch and enter the
        // writer. Until it has, the discard below would simply succeed.
        await fulfillment(of: [writeStarted], timeout: 5)

        let replacement = PipelineQueue(logDir: logDir)
        replacement.adoptJobs(of: replaced)
        try replacement.insertJobForTesting(job("current", state: .done))
        replacement.saveSnapshot()
        try await waitForSnapshot(toContain: 2)

        release.signal()
        await fulfillment(of: [writeFinished], timeout: 5)
        // The replacement's own write is already on disk, so anything that
        // lands after it can only be the stalled one.
        try await Task.sleep(for: .milliseconds(200))

        let onDisk = try snapshotOnDisk()
        // Strict by default: the run fails if the overwrite stops happening, so
        // the marker cannot outlive the defect quietly. Giving the jobs list and
        // its file a single owner is what removes it, and this is the
        // assertion that change is measured against.
        XCTExpectFailure("a stalled write of the replaced queue still overwrites its replacement's state") {
            XCTAssertEqual(
                Set(onDisk.map(\.meetingTitle)), ["stale", "current"],
                "a job the live queue holds vanished from the snapshot",
            )
        }
    }

    /// The pending-write drop does work for the case it was written for: a
    /// write the replaced queue still owes and has not started.
    func testDiscardDropsAWriteThatHasNotStarted() async throws {
        let writes = WriteRecorder()
        let recording: @Sendable ([PipelineJob], URL) -> Void = { jobs, _ in
            Task { await writes.record(jobs.count) }
        }
        let replaced = PipelineQueue(logDir: logDir, snapshotWriter: recording)
        try replaced.insertJobForTesting(job("stale", state: .transcribing))
        replaced.saveSnapshot()
        replaced.discardPendingSnapshot()

        try await Task.sleep(for: .milliseconds(300))

        let counts = await writes.counts
        XCTAssertTrue(
            counts.isEmpty,
            "a dropped batch still reached the writer: \(counts)",
        )
    }

    private func waitForSnapshot(toContain count: Int) async throws {
        for _ in 0 ..< 50 {
            if let jobs = try? PipelineSnapshot.load(from: logDir), jobs.count == count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the snapshot never reached \(count) jobs")
    }
}

private actor WriteRecorder {
    private(set) var counts: [Int] = []

    func record(_ count: Int) {
        counts.append(count)
    }
}
