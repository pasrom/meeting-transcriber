@testable import MeetingTranscriber
import XCTest

/// Orphan recovery scans staging off the main actor and only then adds jobs.
/// A recording the watch loop enqueues, or another queue starts running, while
/// that scan is out was in neither set the recovery checked before it left,
/// so it has to be checked again on the way back. Otherwise the same file runs
/// twice, and the second job ends in an error notification.
///
/// The scan and the adoption are driven as two calls so the test can put the
/// enqueue exactly where the watch loop's lands in production: between them.
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class OrphanRecoveryRaceTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "OrphanRecoveryRaceTests")
    }

    private func stageMix(named name: String) throws -> URL {
        let recDir = tmpDir.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let mix = recDir.appendingPathComponent(name)
        try Data(repeating: 0xFF, count: 100).write(to: mix)
        return mix
    }

    func testARecordingEnqueuedDuringTheScanIsNotRecoveredAsWell() async throws {
        let enqueued = try stageMix(named: "20260311_100000_mix.wav")
        let orphan = try stageMix(named: "20260311_090000_mix.wav")
        let queue = PipelineQueue(logDir: tmpDir)

        let candidates = await queue.scanForOrphanedRecordings(recordingsDir: enqueued.deletingLastPathComponent())
        XCTAssertEqual(candidates.count, 2, "test premise: the scan saw both recordings")
        queue.insertJobForTesting(PipelineJob(
            meetingTitle: "Standup", appName: "Teams",
            mixPath: enqueued, appPath: nil, micPath: nil, micDelay: 0,
        ))
        queue.adoptOrphanedRecordings(candidates)

        XCTAssertEqual(
            queue.jobs.compactMap(\.mixPath?.lastPathComponent).sorted(),
            [orphan.lastPathComponent, enqueued.lastPathComponent],
            "the enqueued recording got a second job, or the real orphan was dropped",
        )
    }

    func testARecordingAnotherQueueStartedDuringTheScanIsNotRecovered() async throws {
        let mix = try stageMix(named: "20260311_100000_mix.wav")
        let registry = InFlightRunRegistry()
        let queue = PipelineQueue(logDir: tmpDir, inFlightRuns: registry)

        let candidates = await queue.scanForOrphanedRecordings(recordingsDir: mix.deletingLastPathComponent())
        XCTAssertEqual(candidates.count, 1, "test premise: the scan saw the recording")
        XCTAssertEqual(registry.begin(jobID: UUID(), mixPath: mix), .claimed)
        queue.adoptOrphanedRecordings(candidates)

        XCTAssertTrue(queue.jobs.isEmpty, "recovered a recording another queue started running during the scan")
    }

    /// A job for the recording that was cancelled while the scan was out has
    /// already left the list, but its cancel was recorded in the ledger, and
    /// that has to hold too.
    func testARecordingCancelledDuringTheScanIsNotRecovered() async throws {
        let mix = try stageMix(named: "20260311_100000_mix.wav")
        let queue = PipelineQueue(logDir: tmpDir, stagingDir: mix.deletingLastPathComponent())

        let candidates = await queue.scanForOrphanedRecordings(recordingsDir: mix.deletingLastPathComponent())
        XCTAssertEqual(candidates.count, 1, "test premise: the scan saw the recording")
        queue.processedLedger.markProcessed(mixPath: mix)
        queue.adoptOrphanedRecordings(candidates)

        XCTAssertTrue(queue.jobs.isEmpty, "recovered a recording that was cancelled during the scan")
    }
}
