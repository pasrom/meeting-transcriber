@testable import MeetingTranscriber
import os
import XCTest

/// The compactor when something stands in its way: a taken name, a failed
/// verify, a full disk, an unsaved registry, a missing or foreign output
/// folder, a cancelled job's recording; and its scope and its sweep.
@MainActor
final class RecordingCompactionFailureTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var fixture: RetentionQueueFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try RetentionQueueFixture(tmpDir: makeTempDirectory(prefix: "recording_compaction_failure"))
        fixture.enabled = false
    }

    override func tearDown() async throws {
        fixture = nil
        try await super.tearDown()
    }

    private var recordings: URL {
        fixture.recordingsDir
    }

    // MARK: - Failures

    func testAnExistingUnlistedDestinationIsNeverOverwritten() async throws {
        let compaction = fixture.makeCompaction(codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        let foreign = try compressedTrack(tracks[1])
        try Data("someone else's file".utf8).write(to: foreign)

        compaction.codecStatus = .available
        await queue.compactRecordings()

        XCTAssertEqual(try Data(contentsOf: foreign), Data("someone else's file".utf8))
        XCTAssertTrue(CompactionDisk.exists(tracks[1]), "the WAV whose name was taken must stay")
        XCTAssertFalse(fixture.listedNames.contains(foreign.lastPathComponent))
        XCTAssertFalse(CompactionDisk.exists(tracks[0]))
        XCTAssertFalse(CompactionDisk.exists(tracks[2]))
        XCTAssertEqual(compaction.awaitingCount, 0, "a taken name does not free itself; the mark goes")
    }

    func testAFailedVerifyKeepsTheSourceAndClearsTheMark() async throws {
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { _, _ in throw KeptRecordingCompressor.Failure.mismatch }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)

        await waitFor(compaction.awaitingCount == 0 && !compaction.isRunning, timeout: .seconds(10))

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists))
        XCTAssertEqual(compaction.awaitingCount, 0, "a mismatch fails the same way on every launch")
    }

    func testADiskFullEncodeKeepsTheSourceAndLeavesNoPartial() async throws {
        var compressor = KeptRecordingCompressor()
        compressor.afterWrite = { _ in throw POSIXError(.ENOSPC) }
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { [compressor] in try compressor.prepare(source: $0, partial: $1) }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)

        await queue.compactRecordings()

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists))
        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(".") }, [])
        XCTAssertEqual(compaction.awaitingCount, 1, "a full disk can be freed; the mark stays")
    }

    /// Once the probe found no FLAC nothing would ever clear a mark, so none
    /// is set.
    func testNoMarkIsSetWhenTheProbeFoundNoFLAC() async throws {
        let compaction = fixture.makeCompaction(codec: .unavailable(reason: "notNativeFLAC"))
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)

        XCTAssertEqual(compaction.awaitingCount, 0)
        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists))
    }

    /// Switched off while a run is going: the run stops after the step it is
    /// in, removes what it has not committed, and keeps the mark.
    func testSwitchingTheSettingOffStopsTheRun() async throws {
        final class Switch {
            var on = true
        }
        let setting = Switch()
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps) { setting.on }
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        setting.on = false
        gate.open()
        await waitFor(!compaction.isRunning, timeout: .seconds(10))

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists), "a WAV went after the setting was switched off")
        XCTAssertFalse(try tracks.map(compressedTrack).contains(where: CompactionDisk.exists))
        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(".") }, [])
        XCTAssertEqual(compaction.awaitingCount, 1)
    }

    /// A cut-off run left the WAV and its copy both listed. Reading the copy
    /// back fails for a reason that may pass (a read error): the WAV stays,
    /// and so does the mark, so a later run finishes it.
    func testAReadErrorWhileResumingKeepsTheSourceAndTheMark() async throws {
        let steps = RecordingCompactionWorker.Steps.live.with(\.verify) { _, _ in throw POSIXError(.EIO) }
        let compaction = fixture.makeCompaction(steps: steps, codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        let (job, tracks) = try await fixture.finishCompactableRecording(in: queue)
        let copy = try compressedTrack(tracks[0])
        try KeptRecordingCompressor().prepare(source: tracks[0], partial: copy)
        fixture.retention.registry.register(jobID: job.id, paths: [copy], root: fixture.output, recordedAt: Date())
        compaction.codecStatus = .available

        await queue.compactRecordings()

        XCTAssertTrue(CompactionDisk.exists(tracks[0]), "the WAV went without its copy being checked")
        XCTAssertEqual(compaction.awaitingCount, 1)
    }

    /// A re-import that takes the WAV into use after the commit, while the
    /// folder is synced, keeps it; the next run finishes the recording.
    func testAReimportDuringTheFolderSyncKeepsTheSource() async throws {
        let syncing = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let steps = RecordingCompactionWorker.Steps.live.with(\.syncFolder) { folder in
            let first = syncing.withLock { state -> Bool in
                defer { state = true }
                return !state
            }
            if first { release.wait() }
            KeptRecordingCompressor.syncFolder(folder)
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(syncing.withLock { $0 }, timeout: .seconds(10))

        queue.jobs.append(PipelineJob(
            meetingTitle: "Reimport", appName: "File", mixPath: tracks[0], appPath: tracks[1], micPath: tracks[2], micDelay: 0,
        ))
        release.signal()
        await waitFor(!compaction.isRunning, timeout: .seconds(10))

        XCTAssertTrue(CompactionDisk.exists(tracks[0]), "a WAV a waiting job reads was removed")
        XCTAssertEqual(fixture.unlistedRecordingFiles(), [], "unlisted files")
    }

    func testNothingRunsWhileTheRegistryIsNotPersisted() async throws {
        let compaction = fixture.makeCompaction(codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        let (job, tracks) = try await fixture.finishCompactableRecording(in: queue)
        // A folder where the registry file should be: every save fails now.
        try FileManager.default.removeItem(at: fixture.registryFile)
        try FileManager.default.createDirectory(at: fixture.registryFile, withIntermediateDirectories: true)
        fixture.retention.registry.markOutputExported(jobID: job.id)
        XCTAssertFalse(fixture.retention.registry.isPersisted, "test premise: the last save failed")

        compaction.codecStatus = .available
        await queue.compactRecordings()

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists))
        XCTAssertFalse(try tracks.map(compressedTrack).contains(where: CompactionDisk.exists))
    }

    // MARK: - Scope, sweep, reach

    func testTheScopeIsHeldFromTheFirstTrackToTheLastAndClosedOnce() async throws {
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        let scope = SecurityScopeAccess(
            start: { url in events.withLock { $0.append("start \(url.lastPathComponent)") }; return true },
            stop: { url in events.withLock { $0.append("stop \(url.lastPathComponent)") } },
        )
        let steps = RecordingCompactionWorker.Steps.live
            .with(\.prepare) { source, partial in
                events.withLock { $0.append("encode") }
                try KeptRecordingCompressor().prepare(source: source, partial: partial)
            }
            .with(\.unlink) { url in
                events.withLock { $0.append("unlink") }
                try RecordingFileDeleter.unlinkFile(url)
            }
        let compaction = fixture.makeCompaction(steps: steps, codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        _ = try await fixture.finishCompactableRecording(in: queue)
        compaction.codecStatus = .available
        // The run's own scope, on the object the caller passes, with no
        // queue holding one: a rebuild can release the queue's mid-run.
        let output = fixture.output

        await compaction.run(.init(
            excludedPaths: { [] }, repointJobAudio: { _, _, _ in }, outputRoot: output, scopeRoot: output, securityScope: scope,
        ))

        let name = output.lastPathComponent
        XCTAssertEqual(
            events.withLock { $0 },
            ["start \(name)"] + Array(repeating: ["encode", "unlink"], count: 3).flatMap(\.self) + ["stop \(name)"],
            "one scope from before the first track to after the last",
        )
    }

    /// The sweep of leftover partials runs at every run start, whatever the
    /// setting says.
    func testARunSweepsAnOldPartialWithTheSettingOff() async throws {
        // A day and more on: the partial written now is old by then.
        let later = Date().addingTimeInterval(2 * RecordingCompaction.partialMaxAge)
        let compaction = fixture.makeCompaction(isEnabled: { false }, now: { later })
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let leftover = recordings.appendingPathComponent(".20270115_1200_sync_ab12cd34_mic.partial.flac")
        try Data("old".utf8).write(to: leftover)

        await compaction.run(fixture.compactionContext())

        XCTAssertFalse(CompactionDisk.exists(leftover))
    }

    /// The age is the partial's own: a copy carries its source's dates, so a
    /// modification date a year back still means a copy written just now.
    /// Status-change times cannot be set back, so the cutoff moves instead.
    func testTheSweepRemovesOnlyOldPartialsOfItsOwnPattern() throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        func write(_ name: String) throws -> URL {
            let url = recordings.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-365 * 86400)], ofItemAtPath: url.path,
            )
            return url
        }
        let partial = try write(".b_ab12cd34_app.partial.flac")
        let unrelated = try write(".b_ab12cd34_mix.wav.partial")
        let finder = try write(".DS_Store")
        let inWork = try write(".c_ab12cd34_mic.partial.flac")
        let keeping: Set = [RecordingRetentionPolicy.pathKey(inWork)]

        let notYet = RecordingCompaction.liveSweep(
            folder: recordings, olderThan: Date().addingTimeInterval(-RecordingCompaction.partialMaxAge), keeping: keeping,
        )
        XCTAssertEqual(notYet, 0, "a partial written now is not a day old, whatever its modification date says")

        let removed = RecordingCompaction.liveSweep(
            folder: recordings, olderThan: Date().addingTimeInterval(RecordingCompaction.partialMaxAge), keeping: keeping,
        )
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(CompactionDisk.exists(partial))
        XCTAssertTrue([unrelated, finder, inWork].allSatisfy(CompactionDisk.exists))
    }

    func testACancelledJobsRecordingIsNeverCompressed() async throws {
        let compaction = fixture.makeCompaction()
        let queue = fixture.makeQueue(compaction: compaction)
        let cancelled = try fixture.makeRecordedJob(pcm16: true)
        queue.enqueue(cancelled)
        queue.cancelJob(id: cancelled.id)
        await queue.lastRecordingRelocation?.value
        let left = CompactionDisk.recordingNames(in: recordings).filter { $0.hasSuffix(".wav") }
        XCTAssertEqual(left.count, 3, "test premise: the cancelled recording moved to the output folder")

        _ = try await fixture.finishCompactableRecording(in: queue)
        await waitForCompactionIdle(compaction)

        let wavs = CompactionDisk.recordingNames(in: recordings).filter { $0.hasSuffix(".wav") }
        XCTAssertEqual(wavs, left, "the cancelled job's recording is not listed and must stay as it is")
    }

    func testAMissingRootKeepsTheMark() async throws {
        let compaction = fixture.makeCompaction(codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        _ = try await fixture.finishCompactableRecording(in: queue)
        let moved = fixture.tmpDir.appendingPathComponent("unplugged")
        try FileManager.default.moveItem(at: fixture.output, to: moved)
        compaction.codecStatus = .available

        await queue.compactRecordings()

        XCTAssertEqual(compaction.awaitingCount, 1, "an unplugged drive is no reason to give up on the recording")
    }

    func testAnEntryUnderAnotherRootIsSkippedAndKeepsItsMark() async throws {
        let compaction = fixture.makeCompaction(codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        let (job, tracks) = try await fixture.finishCompactableRecording(in: queue)
        let other = fixture.tmpDir.appendingPathComponent("Other", isDirectory: true)
        let otherRecordings = other.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRecordings, withIntermediateDirectories: true)
        let elsewhere = otherRecordings.appendingPathComponent(tracks[0].lastPathComponent)
        try FileManager.default.copyItem(at: tracks[0], to: elsewhere)
        fixture.retention.registry.register(jobID: job.id, paths: [elsewhere], root: other, recordedAt: Date())
        fixture.retention.registry.markAwaiting(.flac, jobID: job.id, root: other)
        compaction.codecStatus = .available

        await queue.compactRecordings()

        XCTAssertTrue(CompactionDisk.exists(elsewhere), "a recording under another folder was touched")
        let entries = CompactionDisk.entries(at: fixture.registryFile)
        XCTAssertEqual(entries.first { $0.root.standardizedFileURL == other.standardizedFileURL }?.awaiting, [.flac])
        XCTAssertEqual(entries.first { $0.root.standardizedFileURL == fixture.output.standardizedFileURL }?.awaiting, [])
    }
}
