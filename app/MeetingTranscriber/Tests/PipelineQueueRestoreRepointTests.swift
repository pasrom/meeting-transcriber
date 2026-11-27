@testable import MeetingTranscriber
import XCTest

/// A job whose snapshot still names its staging audio after stage 3 moved
/// some or all of it: the restore points it at the moved files, takes the
/// staging sidecar along and lists the recording for retention, instead of
/// discarding the job or running it with a track missing.
///
/// Each state is made from a real run's output: the job is run once, so the
/// files are where stage 3 puts them under the names it uses, and the state
/// at the kill is then rebuilt from that by moving files back.
@MainActor
final class PipelineQueueRestoreRepointTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var fixture: RetentionQueueFixture!
    private let micDelay: TimeInterval = 0.25

    override func setUp() async throws {
        try await super.setUp()
        fixture = try RetentionQueueFixture(tmpDir: makeTempDirectory(prefix: "restore_repoint"))
        // Off, so no pass deletes the relocated audio these states are built from.
        fixture.enabled = false
    }

    override func tearDown() async throws {
        fixture = nil
        try await super.tearDown()
    }

    /// A recording in staging with its sidecar, as the watch loop enqueues it.
    private struct Recorded {
        let job: PipelineJob
        let stagingSidecar: URL
        let sidecarData: Data
    }

    private func makeRecording() throws -> Recorded {
        let job = try fixture.makeRecordedJob()
        let mix = try XCTUnwrap(job.mixPath)
        let sidecar = try XCTUnwrap(RecordingSidecar.recordingSidecarURL(besideMix: mix))
        try RecordingSidecar(
            title: job.meetingTitle, appName: job.appName,
            startedAt: job.artifactStartTime, stoppedAt: job.artifactStartTime.addingTimeInterval(60),
            participants: [], micDelaySeconds: micDelay, trigger: .auto,
            mixFilename: mix.lastPathComponent,
            appFilename: job.appPath?.lastPathComponent, micFilename: job.micPath?.lastPathComponent,
        ).write(to: sidecar)
        return try Recorded(job: job, stagingSidecar: sidecar, sidecarData: Data(contentsOf: sidecar))
    }

    /// Run `recorded` once, so its audio and sidecar are in the output folder
    /// and listed, and return the finished job.
    private func relocate(_ recorded: Recorded) async throws -> PipelineJob {
        let queue = fixture.makeQueue()
        queue.enqueue(recorded.job)
        await queue.processNext()
        await queue.awaitSnapshotFlush()
        let finished = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(finished.state, .done)
        XCTAssertFalse(fixture.exists(recorded.stagingSidecar), "the run took the sidecar along")
        return finished
    }

    private func relocatedSidecar(of finished: PipelineJob) throws -> URL {
        try XCTUnwrap(RecordingSidecar.recordingSidecarURL(besideMix: XCTUnwrap(finished.mixPath)))
    }

    /// Rebuild the state of a kill inside the move from the finished run:
    /// `tracks` back in staging (keypaths of the job's slots), the sidecar
    /// back beside the staging mix, and nothing listed, since stage 3
    /// registers after its last move.
    private func rewind(
        _ recorded: Recorded, _ finished: PipelineJob, unmoving tracks: [KeyPath<PipelineJob, URL?>],
        stagingSidecar: Data? = nil,
    ) throws {
        for track in tracks {
            try FileManager.default.moveItem(at: XCTUnwrap(finished[keyPath: track]), to: XCTUnwrap(recorded.job[keyPath: track]))
        }
        try FileManager.default.removeItem(at: relocatedSidecar(of: finished))
        try (stagingSidecar ?? recorded.sidecarData).write(to: recorded.stagingSidecar)
        forgetEverything(of: finished)
    }

    private func forgetEverything(of finished: PipelineJob) {
        fixture.retention.registry.forget(fixture.retention.registry.entries.flatMap(\.paths), of: finished.id)
        XCTAssertTrue(fixture.retention.registry.entries.isEmpty)
    }

    /// The keys of everything stage 3 relocates for `finished`: its three
    /// tracks and the sidecar.
    private func relocatedKeys(of finished: PipelineJob) throws -> Set<String> {
        try Set((fixture.relocatedTracks(of: finished) + [relocatedSidecar(of: finished)]).map(RecordingRetentionPolicy.pathKey))
    }

    /// Write the snapshot a kill left: the job as enqueued, naming staging,
    /// interrupted in `state`.
    private func writeSnapshot(_ jobs: [PipelineJob], state: JobState = .diarizing) throws {
        let interrupted = jobs.map { job -> PipelineJob in
            var job = job
            if job.state == .waiting { job.state = state }
            return job
        }
        try JSONEncoder().encode(interrupted)
            .write(to: fixture.logDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))
    }

    private func restore() async -> PipelineQueue {
        let restored = fixture.makeQueue()
        restored.loadSnapshot()
        await restored.awaitProcessing()
        return restored
    }

    private func eventLog(of queue: PipelineQueue) -> String {
        (try? String(contentsOf: queue.eventLog.path, encoding: .utf8)) ?? ""
    }

    private func listedPaths(of jobID: UUID) -> Set<String> {
        Set(fixture.retention.registry.entries.filter { $0.jobID == jobID }
            .flatMap(\.paths).map(RecordingRetentionPolicy.pathKey))
    }

    private func assertRanOnBothTracks(_ restored: PipelineQueue, file: StaticString = #filePath, line: UInt = #line) {
        let job = restored.jobs.first
        XCTAssertEqual(job?.state, .done, file: file, line: line)
        XCTAssertEqual(job?.trackViability, .both, "a track missing at the run reads as empty", file: file, line: line)
        XCTAssertEqual((restored.engine as? MockEngine)?.transcribeCallCount, 2, file: file, line: line)
    }

    // MARK: - Tests

    /// The common state: stage 3 moved and listed everything, and the
    /// snapshot naming the new paths had not landed yet.
    func testAJobKilledAfterItsAudioWasMovedAndListedFinishesWithoutASecondEntry() async throws {
        let recorded = try makeRecording()
        let finished = try await relocate(recorded)
        let sidecar = try relocatedSidecar(of: finished)
        let sidecarBefore = try Data(contentsOf: sidecar)
        let listedBefore = listedPaths(of: finished.id)
        XCTAssertEqual(listedBefore, try relocatedKeys(of: finished))
        try writeSnapshot([recorded.job])

        let restored = await restore()

        assertRanOnBothTracks(restored)
        let job = try XCTUnwrap(restored.jobs.first)
        XCTAssertEqual(try fixture.relocatedTracks(of: job), try fixture.relocatedTracks(of: finished))
        XCTAssertEqual(fixture.retention.registry.entries.count, 1, "no second entry for the same recording")
        XCTAssertEqual(listedPaths(of: finished.id), listedBefore)
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBefore, "the relocated sidecar is left as it is")
        XCTAssertFalse(fixture.exists(recorded.stagingSidecar))
        let log = eventLog(of: restored)
        let repointed = log.split(separator: "\n").filter { $0.contains("repointed_relocated_audio") }
        XCTAssertEqual(repointed.count, 1)
        XCTAssertEqual(
            repointed.first?.contains("\"from\":\"diarizing\""), true,
            "the record names the stage the job was interrupted in",
        )
        XCTAssertFalse(log.contains("discarded_missing_audio"))
    }

    /// A job another queue is still running is that run's to finish: the
    /// restore drops it, and must not move its sidecar or list its files first.
    func testAJobAnotherQueueStillRunsIsNotRepointed() async throws {
        let recorded = try makeRecording()
        let finished = try await relocate(recorded)
        try rewind(recorded, finished, unmoving: [\.appPath, \.micPath])
        try writeSnapshot([recorded.job])
        let restored = fixture.makeQueue()
        XCTAssertEqual(restored.inFlightRuns.begin(jobID: recorded.job.id, mixPath: recorded.job.mixPath), .claimed)

        restored.loadSnapshot()

        XCTAssertTrue(restored.jobs.isEmpty, "test premise: the in-flight rule dropped it")
        XCTAssertTrue(fixture.exists(recorded.stagingSidecar))
        XCTAssertTrue(fixture.retention.registry.entries.isEmpty)
        XCTAssertFalse(eventLog(of: restored).contains("repointed_relocated_audio"))
    }

    /// Killed while the app track was being copied to another volume: the mix
    /// is in the output folder, the other tracks and the sidecar are still in
    /// staging, and nothing is listed yet, because stage 3 registers after
    /// the last move.
    func testAJobKilledWhileItsAppTrackWasCopiedRunsOnBothTracksAndListsEveryFile() async throws {
        let recorded = try makeRecording()
        let finished = try await relocate(recorded)
        let sidecar = try relocatedSidecar(of: finished)
        try rewind(recorded, finished, unmoving: [\.appPath, \.micPath])
        try writeSnapshot([recorded.job], state: .transcribing)

        let restored = await restore()

        assertRanOnBothTracks(restored)
        XCTAssertFalse(fixture.exists(recorded.stagingSidecar), "the sidecar left staging with the mix")
        let moved = try XCTUnwrap(RecordingSidecar.read(from: sidecar))
        XCTAssertEqual(moved.micDelaySeconds, micDelay)
        XCTAssertEqual(moved.files.mix, finished.mixPath?.lastPathComponent, "it names the relocated tracks")
        XCTAssertEqual(moved.files.app, finished.appPath?.lastPathComponent)
        XCTAssertEqual(fixture.retention.registry.entries.count, 1)
        XCTAssertEqual(
            listedPaths(of: finished.id), try relocatedKeys(of: finished),
            "every track and the sidecar are listed, so retention removes the recording whole",
        )
    }

    /// Killed after the second move: repointing the mix alone would leave
    /// the app slot naming a staging file that is gone.
    func testAJobKilledAfterTwoTracksMovedRunsOnBothTracks() async throws {
        let recorded = try makeRecording()
        let finished = try await relocate(recorded)
        try rewind(recorded, finished, unmoving: [\.micPath])
        try writeSnapshot([recorded.job])

        let restored = await restore()

        assertRanOnBothTracks(restored)
        XCTAssertEqual(listedPaths(of: finished.id), try relocatedKeys(of: finished))
    }

    /// Killed after stage 3 moved every file, the sidecar included, but before
    /// it registered them: the sidecar already under the stem is listed too.
    func testASidecarStage3MovedBeforeTheKillIsListedWithTheTracks() async throws {
        let recorded = try makeRecording()
        let finished = try await relocate(recorded)
        forgetEverything(of: finished)
        try writeSnapshot([recorded.job])

        let restored = await restore()

        assertRanOnBothTracks(restored)
        XCTAssertEqual(listedPaths(of: finished.id), try relocatedKeys(of: finished))
    }

    /// A staging sidecar this build cannot read is not moved, and nothing that
    /// is not the recording's sidecar is listed. The job still runs.
    func testAnUnreadableStagingSidecarIsLeftWhereItIs() async throws {
        let recorded = try makeRecording()
        let finished = try await relocate(recorded)
        try rewind(recorded, finished, unmoving: [\.appPath, \.micPath], stagingSidecar: Data("not json".utf8))
        try writeSnapshot([recorded.job])

        let restored = await restore()

        assertRanOnBothTracks(restored)
        XCTAssertEqual(try Data(contentsOf: recorded.stagingSidecar), Data("not json".utf8))
        try XCTAssertFalse(fixture.exists(relocatedSidecar(of: finished)))
        XCTAssertEqual(listedPaths(of: finished.id), try Set(fixture.relocatedTracks(of: finished).map(RecordingRetentionPolicy.pathKey)))
    }

    /// A production snapshot carries the stem the run moved under
    /// (`namingSlug`). When the stem rebuilt from the job differs from it (the
    /// time zone changed between the run and the restore), the recorded one
    /// is where the audio is.
    func testTheStemTheRunRecordedIsWhereTheAudioIsFound() async throws {
        let recorded = try makeRecording()
        let finished = try await relocate(recorded)
        let recordedStem = "20000101_0000_weekly_sync_\(finished.shortID)"
        let fm = FileManager.default
        for (track, suffix) in try zip(fixture.relocatedTracks(of: finished), RecordingFileSuffix.all) {
            try fm.moveItem(at: track, to: fixture.recordingsDir.appendingPathComponent(recordedStem + suffix))
        }
        var snapshotted = recorded.job
        snapshotted.namingSlug = recordedStem
        try writeSnapshot([snapshotted])

        let restored = await restore()

        assertRanOnBothTracks(restored)
        XCTAssertEqual(
            restored.jobs.first?.mixPath?.lastPathComponent, recordedStem + RecordingFileSuffix.mix,
        )
    }

    func testAJobWhoseAudioIsGoneEverywhereIsStillDiscardedWithItsEvent() async throws {
        let recorded = try makeRecording()
        for path in recorded.job.audioPaths {
            try FileManager.default.removeItem(at: path)
        }
        try writeSnapshot([recorded.job])

        let restored = await restore()

        XCTAssertTrue(restored.jobs.isEmpty)
        let log = eventLog(of: restored)
        XCTAssertTrue(log.contains("discarded_missing_audio"))
        XCTAssertFalse(log.contains("repointed_relocated_audio"))
        XCTAssertTrue(fixture.retention.registry.entries.isEmpty)
        XCTAssertTrue(fixture.exists(recorded.stagingSidecar), "nothing to repoint, so the sidecar stays")
    }

    /// A second job for the same recording (one refused as "already being
    /// processed") names the same staging files. It must not be pointed at
    /// the first job's relocated audio: it would run the recording again and
    /// list it a second time.
    func testADuplicateErrorJobIsNotRepointedOntoAnotherJobsFiles() async throws {
        let recorded = try makeRecording()
        let finished = try await relocate(recorded)
        var duplicate = PipelineJob(
            meetingTitle: recorded.job.meetingTitle, appName: recorded.job.appName,
            mixPath: recorded.job.mixPath, appPath: recorded.job.appPath, micPath: recorded.job.micPath,
            micDelay: 0, meetingStartTime: recorded.job.meetingStartTime,
        )
        duplicate.state = .error
        duplicate.error = "This recording is already being processed"
        try writeSnapshot([recorded.job, duplicate])

        let restored = await restore()

        XCTAssertEqual(restored.jobs.map(\.id), [finished.id], "the duplicate is discarded as before")
        XCTAssertTrue(listedPaths(of: duplicate.id).isEmpty)
        XCTAssertEqual(fixture.retention.registry.entries.count, 1)
        let duplicateEvents = eventLog(of: restored).split(separator: "\n").filter { $0.contains(duplicate.id.uuidString) }
        XCTAssertTrue(duplicateEvents.contains { $0.contains("discarded_missing_audio") })
        XCTAssertFalse(duplicateEvents.contains { $0.contains("repointed_relocated_audio") })
    }
}
