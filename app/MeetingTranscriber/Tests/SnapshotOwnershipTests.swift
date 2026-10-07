@testable import MeetingTranscriber
import XCTest

/// Who owns the queue snapshot file.
///
/// The jobs list and its snapshot live in a fixed `logDir` but hang off the
/// lifetime of a `PipelineQueue` instance. A rebuild therefore has two queues
/// over one file. They write it through the one `PipelineSnapshotStore` for
/// that file, which orders the writes by when they were saved, whichever queue
/// saved them.
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

    /// A write of the replaced queue that is already inside the writer when
    /// the queue is replaced (`replaceItemAt` can stall for seconds on macOS 26)
    /// lands first, and the replacement's later save lands after it, so the
    /// file ends with the replacement's state. With a writer per queue the
    /// stalled write landed last and the file described the queue that went
    /// away; a restart restored from there, which is how a finished job got
    /// queued a second time, the failure `adoptJobs` cites as issue #744. This
    /// was pinned as a known failure before the single writer existed.
    func testAStalledWriteOfTheReplacedQueueLandsBeforeTheReplacementsState() async throws {
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
        // writer, so the replacement is built while that write is stalled.
        await fulfillment(of: [writeStarted], timeout: 5)

        let replacement = PipelineQueue(logDir: logDir)
        replacement.adoptJobs(of: replaced)
        try replacement.insertJobForTesting(job("current", state: .done))
        replacement.saveSnapshot()
        // A window for the replacement's write to land while the stalled one
        // is still held. A writer per queue uses it, so the stalled write then
        // lands last; the single writer keeps it queued behind the stalled
        // one. Without the window the two land in either order on the old
        // design, and the test could not tell the designs apart.
        try await Task.sleep(for: .milliseconds(300))
        let titlesBeforeRelease = Set(((try? PipelineSnapshot.load(from: logDir)) ?? []).map(\.meetingTitle))
        XCTAssertFalse(
            titlesBeforeRelease.contains("current"),
            "the replacement's write landed before the stalled write of the replaced queue",
        )

        release.signal()
        await fulfillment(of: [writeFinished], timeout: 5)
        await replacement.awaitSnapshotFlush()

        XCTAssertEqual(
            try Set(snapshotOnDisk().map(\.meetingTitle)), ["stale", "current"],
            "a job the live queue holds vanished from the snapshot",
        )
    }
}
