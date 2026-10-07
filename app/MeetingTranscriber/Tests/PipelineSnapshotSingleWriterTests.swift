@testable import MeetingTranscriber
import os
import XCTest

/// Every queue that writes a snapshot file writes it through one writer.
///
/// `PipelineController.rebuild()` replaces the queue while the replaced one
/// may still be writing the same `pipeline_queue.json`. With a worker per
/// queue the two writes raced: the replaced queue's late write could land
/// after the newer queue's and put the older state back on disk, and the newer
/// queue read the file before the older write had landed, so it started from
/// a state that was already out of date. Both are silent: the file simply
/// describes another moment, and the next launch restores that.
@MainActor
final class PipelineSnapshotSingleWriterTests: XCTestCase {
    /// A queue whose writer takes long enough that its write is still in
    /// flight when the next queue starts.
    private func makeSlowSnapshotQueue(in dir: URL) -> PipelineQueue {
        // swiftlint:disable:next trailing_closure
        PipelineQueue(logDir: dir, snapshotWriter: { jobs, url in
            Thread.sleep(forTimeInterval: 0.3)
            try PipelineSnapshot.save(jobs, to: url)
        })
    }

    /// A job the restore keeps as it is: terminal but not `.done` (which the
    /// restore discards), and without a mix path the missing-audio rule could
    /// drop.
    private func makeFailedJob(title: String) -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: title, appName: "Microsoft Teams",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .error
        return job
    }

    /// The replacement reads the state the replaced queue last saved, not the
    /// file as it was before that save landed, and its own later write is the
    /// one that stays on disk.
    func testAReplacementQueueStartsFromTheLatestStateAndItsWriteWins() async throws {
        let dir = try makeTempDirectory(prefix: "single_writer")
        let replaced = makeSlowSnapshotQueue(in: dir)
        let first = makeFailedJob(title: "Saved By The Replaced Queue")
        replaced.insertJobForTesting(first)
        replaced.saveSnapshot()

        let current = PipelineQueue(logDir: dir)
        current.loadSnapshot()
        XCTAssertEqual(
            current.jobs.map(\.id), [first.id],
            "the replacement restored the file from before the replaced queue's last write",
        )
        let second = makeFailedJob(title: "Saved By The Current Queue")
        current.insertJobForTesting(second)
        current.saveSnapshot()

        await current.awaitSnapshotFlush()
        await replaced.awaitSnapshotFlush()

        let onDisk = try XCTUnwrap(try PipelineSnapshot.load(from: dir))
        XCTAssertEqual(
            onDisk.map(\.id), current.jobs.map(\.id),
            "an older queue's late write overwrote the newer queue's snapshot",
        )
    }

    /// The order on disk follows the order of the saves, whichever queue made
    /// them and however long each write takes.
    func testTheLaterSaveIsTheOneOnDiskWhenTheEarlierWriteIsSlower() async throws {
        let dir = try makeTempDirectory(prefix: "single_writer_order")
        let slow = makeSlowSnapshotQueue(in: dir)
        slow.insertJobForTesting(makeFailedJob(title: "Earlier"))
        slow.saveSnapshot()

        let fast = PipelineQueue(logDir: dir)
        let later = makeFailedJob(title: "Later")
        fast.insertJobForTesting(later)
        fast.saveSnapshot()

        await fast.awaitSnapshotFlush()
        await slow.awaitSnapshotFlush()

        let onDisk = try XCTUnwrap(try PipelineSnapshot.load(from: dir))
        XCTAssertEqual(onDisk.map(\.id), [later.id])
    }

    /// A rebuild adopts the replaced queue's jobs from memory and writes only
    /// when the adoption dropped something. A job that has just failed is
    /// adopted unchanged, so the only write that holds its failure is the one
    /// the replaced queue still owes. Dropping that write (as a per-queue
    /// writer had to, to keep two writers off one staging file) left the job
    /// on disk as running, and the next launch would have run it again.
    func testAnAdoptionThatWritesNothingKeepsTheReplacedQueuesLastWrite() async throws {
        let dir = try makeTempDirectory(prefix: "single_writer_adopt")
        let replaced = makeSlowSnapshotQueue(in: dir)
        var job = makeFailedJob(title: "Fails Just Before The Rebuild")
        job.state = .transcribing
        replaced.insertJobForTesting(job)
        replaced.saveSnapshot()
        // Queued behind the write in flight: the transition to failed.
        replaced.jobs[0].state = .error
        replaced.saveSnapshot()

        let current = PipelineQueue(logDir: dir)
        current.adoptJobs(of: replaced)
        XCTAssertEqual(current.jobs.map(\.state), [.error], "test premise: the failed job is adopted as it is")
        await current.awaitSnapshotFlush()
        await replaced.awaitSnapshotFlush()

        let onDisk = try XCTUnwrap(try PipelineSnapshot.load(from: dir))
        XCTAssertEqual(
            onDisk.map(\.state), [.error],
            "the failure was never written, so the next launch restores the job as interrupted and runs it again",
        )
    }

    /// The writes of a queue that is replaced and then released still land:
    /// they no longer depend on the queue staying alive.
    func testAReleasedQueuesQueuedWriteStillLands() async throws {
        let dir = try makeTempDirectory(prefix: "single_writer_released")
        var replaced: PipelineQueue? = makeSlowSnapshotQueue(in: dir)
        let first = makeFailedJob(title: "Written First")
        replaced?.insertJobForTesting(first)
        replaced?.saveSnapshot()
        // Queued behind the write in flight.
        let queued = makeFailedJob(title: "Queued Behind A Write")
        replaced?.insertJobForTesting(queued)
        replaced?.saveSnapshot()
        replaced = nil

        // Another queue on the same file is how a later reader reaches these
        // writes.
        let observer = PipelineQueue(logDir: dir)
        await observer.awaitSnapshotFlush()

        let onDisk = try XCTUnwrap(try PipelineSnapshot.load(from: dir))
        XCTAssertEqual(onDisk.map(\.id), [first.id, queued.id], "the write queued in the released queue was dropped")
    }

    /// A folder reached through a symlink (the temporary folder is reached as
    /// `/var/...` and as `/private/var/...`) is one file, so it gets one writer.
    func testOneFolderReachedThroughASymlinkHasOneWriter() async throws {
        let base = try makeTempDirectory(prefix: "single_writer_symlink")
        let resolved = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        let dir = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: resolved)
        let viaLink = makeSlowSnapshotQueue(in: dir)
        viaLink.insertJobForTesting(makeFailedJob(title: "Through The Link"))
        viaLink.saveSnapshot()

        let viaTarget = PipelineQueue(logDir: resolved)
        XCTAssertTrue(viaTarget.isSnapshotWorkerActive, "the two spellings of one folder got two writers")
        await viaTarget.awaitSnapshotFlush()
        XCTAssertFalse(viaLink.isSnapshotWorkerActive)
    }

    /// A write that fails has not landed. It used to count as landed: the
    /// writer logged the error and returned, the store let go of the state,
    /// and a quit waiting on the flush was told everything was on disk while
    /// the file still described an older moment.
    func testAWriteThatFailsIsStillOwedAfterTheFlush() async throws {
        let dir = try makeTempDirectory(prefix: "single_writer_failed")
        // swiftlint:disable:next trailing_closure
        let queue = PipelineQueue(logDir: dir, snapshotWriter: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        queue.insertJobForTesting(makeFailedJob(title: "Never Written"))
        queue.saveSnapshot()

        await queue.awaitSnapshotFlush()

        XCTAssertTrue(queue.isSnapshotWorkerActive, "a failed write was reported as landed")
        XCTAssertNil(try PipelineSnapshot.load(from: dir))
    }

    /// The flush tries a failed write once more, so a failure that has passed
    /// (a disk that had a moment ago been full) still lands before a quit.
    func testTheFlushRetriesAWriteThatFailedOnce() async throws {
        let dir = try makeTempDirectory(prefix: "single_writer_retry")
        let attempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        // swiftlint:disable:next trailing_closure
        let queue = PipelineQueue(logDir: dir, snapshotWriter: { jobs, url in
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            if attempt == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            try PipelineSnapshot.save(jobs, to: url)
        })
        let job = makeFailedJob(title: "Written On The Retry")
        queue.insertJobForTesting(job)
        queue.saveSnapshot()

        await queue.awaitSnapshotFlush()

        XCTAssertEqual(try PipelineSnapshot.load(from: dir)?.map(\.id), [job.id])
        XCTAssertFalse(queue.isSnapshotWorkerActive)
    }

    /// One retry per state, not one per store: after a state that kept
    /// failing has had its retry, a new state that fails gets a retry of its
    /// own on the next flush. A full disk that a quit could not get past must
    /// not leave every later state without one.
    func testANewStateThatFailsGetsARetryOfItsOwn() async throws {
        let dir = try makeTempDirectory(prefix: "single_writer_new_state")
        let attempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        // swiftlint:disable:next trailing_closure
        let queue = PipelineQueue(logDir: dir, snapshotWriter: { _, _ in
            attempts.withLock { $0 += 1 }
            throw CocoaError(.fileWriteOutOfSpace)
        })
        queue.insertJobForTesting(makeFailedJob(title: "First State"))
        queue.saveSnapshot()
        await queue.awaitSnapshotFlush()
        await queue.awaitSnapshotFlush()
        XCTAssertEqual(attempts.withLock { $0 }, 2, "test premise: the first state had its write and one retry")

        queue.insertJobForTesting(makeFailedJob(title: "Second State"))
        queue.saveSnapshot()
        await queue.awaitSnapshotFlush()

        XCTAssertEqual(attempts.withLock { $0 }, 4, "the new state's write and its own retry")
    }
}
