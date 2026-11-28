@testable import MeetingTranscriber
import os
import XCTest

/// "Compress Existing Recordings": the compactor's run over every tracked
/// recording that still has WAV tracks. It takes only what the registry
/// lists, works with the FLAC setting off, queues behind a run in progress,
/// leaves every recording whole when cancelled, and counts what it did.
@MainActor
final class RecordingCompactionExplicitRunTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var fixture: RetentionQueueFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try RetentionQueueFixture(tmpDir: makeTempDirectory(prefix: "recording_compaction_explicit"))
        fixture.enabled = false
    }

    override func tearDown() async throws {
        fixture = nil
        try await super.tearDown()
    }

    private var recordings: URL {
        fixture.recordingsDir
    }

    /// A finished 16-bit recording in the output folder, listed but not
    /// marked: one recorded before the FLAC setting was switched on.
    private func registerUnmarkedRecording(under root: URL? = nil) throws -> (jobID: UUID, tracks: [URL]) {
        let root = root ?? fixture.output
        let folder = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = try fixture.makeRecordedJob(in: folder, pcm16: true)
        let tracks = try fixture.relocatedTracks(of: job)
        fixture.retention.registry.register(jobID: job.id, paths: tracks, root: root, recordedAt: Date())
        return (job.id, tracks)
    }

    private func runEveryEntry(
        _ compaction: RecordingCompaction, excluded: Set<String> = [],
    ) async -> RecordingCompactionSummary? {
        await compaction.run(fixture.compactionContext(excluded: excluded), request: .everyEntry)
        return compaction.lastRequestedRun
    }

    // MARK: - Reach

    /// The setting is for recordings still to come; the action is explicit,
    /// so it converts a recording finished while the setting was off.
    func testTheExplicitRunWorksWithTheSettingOff() async throws {
        let compaction = fixture.makeCompaction { false }
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        let original = try fixture.samples(of: tracks)
        XCTAssertEqual(compaction.awaitingCount, 0, "test premise: nothing marked with the setting off")

        await queue.compactRecordings(.everyEntry)

        let copies = try tracks.map(compressedTrack)
        XCTAssertFalse(tracks.contains(where: CompactionDisk.exists), "a WAV survived")
        XCTAssertTrue(try fixture.samples(of: copies) == original, "a copy decodes to other samples")
        XCTAssertEqual(fixture.unlistedRecordingFiles(), [], "unlisted files")
        let summary = try XCTUnwrap(compaction.lastRequestedRun)
        XCTAssertEqual(summary.compressed, 3)
        XCTAssertTrue(summary.explicit)
        XCTAssertFalse(summary.cancelled)
    }

    /// The automatic run, by contrast, takes only marked entries.
    func testAnAutomaticRunLeavesAnUnmarkedRecordingAlone() async throws {
        let compaction = fixture.makeCompaction()
        let (_, tracks) = try registerUnmarkedRecording()

        await compaction.run(fixture.compactionContext())

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists))
        XCTAssertNil(compaction.lastRequestedRun, "an automatic run is no answer to the user's request")
    }

    /// A WAV the registry does not list, right beside a listed recording, is
    /// never touched: the run reads entries, not the folder.
    func testAnUntrackedWAVInTheSameFolderIsUntouched() async throws {
        let compaction = fixture.makeCompaction { false }
        let (_, tracks) = try registerUnmarkedRecording()
        let planted = recordings.appendingPathComponent("20260101_0900_planted_mix.wav")
        try FileManager.default.copyItem(at: tracks[0], to: planted)
        let before = try Data(contentsOf: planted)

        _ = await runEveryEntry(compaction)

        XCTAssertTrue(try tracks.map(compressedTrack).allSatisfy(CompactionDisk.exists), "test premise: the listed one ran")
        XCTAssertEqual(try Data(contentsOf: planted), before)
        XCTAssertFalse(try CompactionDisk.exists(compressedTrack(planted)))
    }

    /// No FLAC on this Mac: nothing is converted, and Settings is told why.
    func testWithoutFLACTheExplicitRunConvertsNothingAndSaysWhy() async throws {
        let compaction = fixture.makeCompaction(codec: .unavailable(reason: "notNativeFLAC"))
        let (_, tracks) = try registerUnmarkedRecording()

        let summary = await runEveryEntry(compaction)

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists))
        XCTAssertEqual(summary?.notRun, .noFLAC)

        compaction.codecStatus = .unknown
        let unconfirmed = await runEveryEntry(compaction)
        XCTAssertEqual(unconfirmed?.notRun, .flacNotConfirmed, "a probe without an answer is not \"no FLAC\"")
    }

    // MARK: - Cancel, and what comes after it

    /// Start `body` in a task and return once it has begun: everything up
    /// to its first suspension is done, and the compactor's queue takes a
    /// request in that first turn.
    private func started(_ body: @escaping @MainActor () async -> Void) async -> Task<Void, Never> {
        let flag = EnteredFlag()
        let task = Task { @MainActor in
            flag.entered = true
            await body()
        }
        await waitFor(flag.entered, timeout: .seconds(5))
        return task
    }

    /// A prepare step that holds the given calls (counted from 1) at their gate.
    private func holding(_ gates: [Int: StepGate]) -> RecordingCompactionWorker.Steps {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        return RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            let call = calls.withLock { count -> Int in
                count += 1
                return count
            }
            await gates[call]?.pass()
        }
    }

    /// A finished meeting asks for its automatic run while the user's run is
    /// being cancelled. That request comes after the cancel, so it still
    /// runs: the cancel ends the pass it was meant for, not the queue.
    func testARequestAfterACancelStillRuns() async throws {
        let gate = StepGate()
        let compaction = fixture.makeCompaction(steps: holding([1: gate]))
        _ = try registerUnmarkedRecording()
        let explicit = await started { _ = await self.runEveryEntry(compaction) }
        // Queued, the loop not yet past its first turn: with no pass going
        // it is not "waiting" for anything.
        XCTAssertEqual(compaction.requestedRun, .running)
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        XCTAssertEqual(compaction.requestedRun, .running)
        compaction.cancelRequestedRun()

        let (laterJob, later) = try registerUnmarkedRecording()
        fixture.retention.registry.markAwaiting(.flac, jobID: laterJob, root: fixture.output)
        let automatic = await started { await compaction.run(self.fixture.compactionContext()) }
        gate.open()
        _ = await explicit.value
        await automatic.value

        XCTAssertEqual(compaction.lastRequestedRun?.cancelled, true, "test premise: the user's run was cancelled")
        XCTAssertTrue(try later.map(compressedTrack).allSatisfy(CompactionDisk.exists), "the request after the cancel was dropped")
        XCTAssertEqual(compaction.awaitingCount, 0)
        XCTAssertEqual(compaction.requestedRun, .idle)
    }

    /// The user's run waits behind an automatic pass, and a meeting that
    /// finishes meanwhile asks for its own automatic pass, which waits with
    /// it. Cancelling the user's pass once it runs must not take that
    /// meeting's conversion with it.
    func testCancellingTheRunningUserPassKeepsTheAutomaticRequestQueuedWithIt() async throws {
        let first = StepGate()
        let usersFirstTrack = StepGate()
        // Calls 1 to 3 are the first meeting's tracks; 4 is the user's run's
        // first track (the unmarked recording, listed before the later one).
        let compaction = fixture.makeCompaction(steps: holding([1: first, 4: usersFirstTrack]))
        let queue = fixture.makeQueue(compaction: compaction)
        _ = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(first.reached == 1, timeout: .seconds(10))
        let (_, unmarked) = try registerUnmarkedRecording()
        let explicit = await started { await queue.compactRecordings(.everyEntry) }
        XCTAssertEqual(compaction.requestedRun, .waiting)
        let (laterJob, later) = try registerUnmarkedRecording()
        fixture.retention.registry.markAwaiting(.flac, jobID: laterJob, root: fixture.output)
        let automatic = await started { await queue.compactRecordings() }

        first.open()
        await waitFor(usersFirstTrack.reached == 1, timeout: .seconds(10))
        XCTAssertEqual(compaction.requestedRun, .running)
        compaction.cancelRequestedRun()
        usersFirstTrack.open()
        await explicit.value
        await automatic.value

        XCTAssertTrue(unmarked.allSatisfy(CompactionDisk.exists), "test premise: the user's run was stopped")
        XCTAssertTrue(try later.map(compressedTrack).allSatisfy(CompactionDisk.exists), "the queued meeting's conversion was lost")
        XCTAssertEqual(compaction.awaitingCount, 0)
    }

    /// Cancel in Settings while the user's run waits behind an automatic
    /// one: the automatic run finishes its recording, the user's never
    /// starts, and Settings shows a cancelled run rather than an older one.
    func testCancellingAWaitingRequestedRunLeavesTheAutomaticRunAlone() async throws {
        let gate = StepGate()
        let compaction = fixture.makeCompaction(steps: holding([1: gate]))
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, marked) = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        let (_, unmarked) = try registerUnmarkedRecording()
        let explicit = await started { await queue.compactRecordings(.everyEntry) }
        XCTAssertEqual(compaction.requestedRun, .waiting)

        compaction.cancelRequestedRun()
        XCTAssertEqual(compaction.requestedRun, .idle)
        XCTAssertEqual(compaction.lastRequestedRun?.cancelled, true)
        XCTAssertEqual(compaction.lastRequestedRun?.compressed, 0)
        gate.open()
        await explicit.value

        XCTAssertTrue(try marked.map(compressedTrack).allSatisfy(CompactionDisk.exists), "the automatic run was stopped")
        XCTAssertTrue(unmarked.allSatisfy(CompactionDisk.exists), "the cancelled run still ran")
        XCTAssertFalse(try unmarked.map(compressedTrack).contains(where: CompactionDisk.exists))
    }

    /// A second request for the user's run queued behind the running one is
    /// part of the same run: Cancel stops both, so nothing starts after it.
    func testCancellingTheUsersRunAlsoDropsADuplicateQueuedBehindIt() async throws {
        let gate = StepGate()
        let compaction = fixture.makeCompaction(steps: holding([1: gate])) { false }
        _ = try registerUnmarkedRecording()
        let first = Task { await runEveryEntry(compaction) }
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        // Listed after the first pass selected, so only a second pass would take it.
        let (_, later) = try registerUnmarkedRecording()
        let second = await started { _ = await self.runEveryEntry(compaction) }

        compaction.cancelRequestedRun()
        gate.open()
        _ = await first.value
        await second.value

        XCTAssertTrue(later.allSatisfy(CompactionDisk.exists), "the duplicate still ran after the cancel")
        XCTAssertFalse(try later.map(compressedTrack).contains(where: CompactionDisk.exists))
        XCTAssertEqual(compaction.requestedRun, .idle)
    }

    /// Switching the setting off stops an automatic run, but nobody pressed
    /// Cancel, so the run's line (in the log and `/state`) does not say so.
    func testSwitchingTheSettingOffIsNotLoggedAsACancel() async throws {
        let gate = StepGate()
        let enabled = OSAllocatedUnfairLock(initialState: true)
        let reported = OSAllocatedUnfairLock<RecordingCompactionSummary?>(initialState: nil)
        let isEnabled: () -> Bool = { enabled.withLock { $0 } }
        let report: (RecordingCompactionSummary) -> Void = { summary in reported.withLock { $0 = summary } }
        let compaction = fixture.makeCompaction(steps: holding([1: gate]), isEnabled: isEnabled, report: report)
        let (jobID, tracks) = try registerUnmarkedRecording()
        fixture.retention.registry.markAwaiting(.flac, jobID: jobID, root: fixture.output)
        let run = Task { await compaction.run(fixture.compactionContext()) }
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        enabled.withLock { $0 = false }
        gate.open()
        await run.value

        XCTAssertTrue(tracks.dropFirst().allSatisfy(CompactionDisk.exists), "test premise: the run stopped")
        let summary = try XCTUnwrap(reported.withLock { $0 })
        XCTAssertEqual(summary.skippedTracks, [.cancelled: 1], "test premise: the switch stopped a track")
        XCTAssertFalse(summary.cancelled, summary.logLine)
    }

    /// A cancel that lands after the run was asked for but before its pass
    /// has started still stops it.
    func testACancelBeforeThePassStartsStopsIt() async throws {
        let compaction = fixture.makeCompaction()
        let (_, tracks) = try registerUnmarkedRecording()

        let run = Task { await runEveryEntry(compaction) }
        // Queued behind `run`'s first turn, which takes the request and
        // creates the loop's task; this runs before that task's first turn.
        let cancel = Task { compaction.cancel() }
        await cancel.value
        _ = await run.value

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists), "the cancel was lost")
        XCTAssertNil(compaction.lastRequestedRun)
    }

    /// A cancel pressed after the last track committed stopped nothing, so
    /// the summary does not say the rest stays WAV, and the sidecar names
    /// the FLAC tracks although the cancel kept the run from finishing the
    /// entry the normal way.
    func testACancelAfterTheLastTrackIsNotReportedAsCancelled() async throws {
        weak var running: RecordingCompaction?
        // The rename runs in the commit turn on the main actor; the last
        // track's is the last step a cancel could stop.
        let cancellingAfterTheLastTrack: (URL, URL) throws -> Void = { from, to in
            try RecordingCompaction.renameExclusive(from, to)
            guard to.lastPathComponent.hasSuffix("_mic.flac") else { return }
            MainActor.assumeIsolated { running?.cancelRequestedRun() }
        }
        let compaction = fixture.makeCompaction(rename: cancellingAfterTheLastTrack)
        running = compaction
        let (jobID, tracks) = try registerUnmarkedRecording()
        let sidecar = try RecordingSidecar.writeTestRecordingSidecar(besideMix: tracks[0])
        fixture.retention.registry.register(jobID: jobID, paths: [sidecar], root: fixture.output, recordedAt: Date())

        let summary = await runEveryEntry(compaction)

        XCTAssertEqual(summary?.compressed, 3, "test premise: every track was converted")
        XCTAssertEqual(summary?.cancelled, false)
        let files = try XCTUnwrap(RecordingSidecar.read(from: sidecar)).files
        XCTAssertEqual(
            [files.mix, files.app, files.mic],
            try tracks.map { try compressedTrack($0).lastPathComponent },
            "the sidecar still names the WAV tracks",
        )
    }

    /// A quit after the last WAV was forgotten and before the sidecar was
    /// rewritten leaves a sidecar naming WAV tracks the entry no longer
    /// lists. The next run changes no name of that entry, finishes it, and
    /// still repairs the sidecar.
    func testAFinishedEntryRepairsTheSidecarNamesACrashLeft() async throws {
        let compaction = fixture.makeCompaction { false }
        let (jobID, tracks) = try registerUnmarkedRecording()
        let sidecar = try RecordingSidecar.writeTestRecordingSidecar(besideMix: tracks[0])
        let copies = try tracks.map(compressedTrack)
        let registry = fixture.retention.registry
        registry.register(jobID: jobID, paths: copies + [sidecar], root: fixture.output, recordedAt: Date())
        registry.forget(tracks, of: jobID)
        registry.markAwaiting(.flac, jobID: jobID, root: fixture.output)

        _ = await runEveryEntry(compaction)

        let files = try XCTUnwrap(RecordingSidecar.read(from: sidecar)).files
        XCTAssertEqual([files.mix, files.app, files.mic], copies.map(\.lastPathComponent))
        XCTAssertEqual(compaction.awaitingCount, 0)
    }

    /// The user's run converts what an automatic one owed, so the entry's
    /// FLAC mark goes too and no launch run comes back for it.
    func testTheExplicitRunClearsTheMarkOfWhatItConverts() async throws {
        let compaction = fixture.makeCompaction { false }
        let (jobID, _) = try registerUnmarkedRecording()
        fixture.retention.registry.markAwaiting(.flac, jobID: jobID, root: fixture.output)
        XCTAssertEqual(compaction.awaitingCount, 1, "test premise")

        _ = await runEveryEntry(compaction)

        XCTAssertEqual(compaction.awaitingCount, 0)
    }

    // MARK: - Cancel

    /// Cancelled while the second track is encoded: the first stays
    /// converted and listed, the second and third stay WAV with the same
    /// samples, no partial copy is left and nothing is unlisted.
    func testCancelMidRunKeepsEveryRecordingIntact() async throws {
        let gate = StepGate()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            if calls.withLock({ $0 += 1; return $0 }) == 2 { await gate.pass() }
        }
        let compaction = fixture.makeCompaction(steps: steps) { false }
        let (_, tracks) = try registerUnmarkedRecording()
        let original = try fixture.samples(of: tracks)

        let run = Task { await runEveryEntry(compaction) }
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        XCTAssertEqual(compaction.progress, RecordingCompactionProgress(total: 3).advanced(by: 1))
        compaction.cancel()
        gate.open()
        let finished = await run.value
        let summary = try XCTUnwrap(finished)

        let first = try compressedTrack(tracks[0])
        XCTAssertTrue(CompactionDisk.exists(first))
        XCTAssertFalse(CompactionDisk.exists(tracks[0]))
        XCTAssertTrue(tracks[1...].allSatisfy(CompactionDisk.exists), "a WAV went after the cancel")
        XCTAssertFalse(try tracks[1...].map(compressedTrack).contains(where: CompactionDisk.exists), "committed after the cancel")
        XCTAssertTrue(try fixture.samples(of: [first] + tracks[1...]) == original, "a track changed")
        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(".") }, [], "a partial was left")
        XCTAssertEqual(fixture.unlistedRecordingFiles(), [], "unlisted files")
        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.compressed, 1)
        XCTAssertEqual(summary.skippedTracks, [.cancelled: 1])
        XCTAssertNil(compaction.progress)
        XCTAssertFalse(compaction.isRunning)
    }

    // MARK: - A run in progress

    /// The user asks while an automatic run is converting another recording,
    /// and a finished job asks for an automatic run after that. The explicit
    /// run waits for the one in progress, is not replaced by the later
    /// request, and no two encodes ever run at once.
    func testTheExplicitRunQueuesBehindARunInProgressAndALaterRequestKeepsIt() async throws {
        let gate = StepGate()
        let active = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            active.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            defer { active.withLock { $0.now -= 1 } }
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        _ = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        let (_, unmarked) = try registerUnmarkedRecording()

        let explicit = await started { await queue.compactRecordings(.everyEntry) }
        XCTAssertEqual(compaction.requestedRun, .waiting)
        let automatic = await started { await queue.compactRecordings() }
        XCTAssertEqual(gate.reached, 1, "a second run started beside the first")
        gate.open()
        await explicit.value
        await automatic.value

        XCTAssertTrue(try unmarked.map(compressedTrack).allSatisfy(CompactionDisk.exists), "the explicit run was dropped")
        XCTAssertFalse(unmarked.contains(where: CompactionDisk.exists))
        XCTAssertEqual(active.withLock(\.most), 1, "two encodes ran at once")
        XCTAssertEqual(compaction.lastRequestedRun?.compressed, 3)
    }

    // MARK: - Summary

    /// Every reason a recording or a track was left as it is gets its own
    /// count: held by a job, under another output folder, nothing left as
    /// WAV, and a file not downloaded from iCloud.
    func testTheSummaryCountsEachSkipReason() async throws {
        let (_, converted) = try registerUnmarkedRecording()
        let (_, held) = try registerUnmarkedRecording()
        _ = try registerUnmarkedRecording(under: fixture.tmpDir.appendingPathComponent("Other", isDirectory: true))
        let (evictedJob, evictedTracks) = try registerUnmarkedRecording()
        fixture.retention.registry.forget(Array(evictedTracks[1...]), of: evictedJob)
        let flacOnly = recordings.appendingPathComponent("20260101_0900_done_mix.flac")
        fixture.retention.registry.register(jobID: UUID(), paths: [flacOnly], root: fixture.output, recordedAt: Date())
        let evicted = evictedTracks[0].lastPathComponent
        let steps = RecordingCompactionWorker.Steps.live.with(\.facts) { source, destination in
            var facts = RecordingCompaction.liveFacts(source: source, destination: destination)
            facts.evicted = source.lastPathComponent == evicted
            return facts
        }
        let compaction = fixture.makeCompaction(steps: steps) { false }
        let wavBytes = try converted.map(fileSize).reduce(0, +)

        let finished = await runEveryEntry(compaction, excluded: [RecordingRetentionPolicy.pathKey(held[0])])
        let summary = try XCTUnwrap(finished)

        XCTAssertEqual(summary.skippedEntries, [.inUse: 1, .otherRoot: 1, .noWAVTrack: 1])
        XCTAssertEqual(summary.skippedTracks, [.evicted: 1])
        XCTAssertEqual(summary.entries, 2)
        XCTAssertEqual(summary.compressed, 3)
        let flacBytes = try converted.map(compressedTrack).map(fileSize).reduce(0, +)
        XCTAssertGreaterThan(wavBytes - flacBytes, 0, "test premise: the copies are smaller")
        XCTAssertEqual(summary.bytesSaved, wavBytes - flacBytes)
        XCTAssertTrue(held.allSatisfy(CompactionDisk.exists))
        XCTAssertTrue(CompactionDisk.exists(evictedTracks[0]))
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
    }

    // MARK: - What Settings counts

    /// The count Settings shows: listed recordings with a WAV track under the
    /// current output folder that no unfinished job holds.
    func testTheCompressibleCountLeavesOutHeldAndOtherFolderEntries() async throws {
        let compaction = fixture.makeCompaction { false }
        _ = try registerUnmarkedRecording()
        let (_, held) = try registerUnmarkedRecording()
        _ = try registerUnmarkedRecording(under: fixture.tmpDir.appendingPathComponent("Other", isDirectory: true))

        XCTAssertEqual(compaction.compressibleCount(under: fixture.output), 2)
        compaction.heldPaths = { [RecordingRetentionPolicy.pathKey(held[1])] }
        XCTAssertEqual(compaction.compressibleCount(under: fixture.output), 1)

        compaction.heldPaths = { [] }
        _ = await runEveryEntry(compaction)
        XCTAssertEqual(compaction.compressibleCount(under: fixture.output), 0, "converted recordings still counted")
    }
}

extension RecordingCompactionProgress {
    func advanced(by steps: Int) -> Self {
        var progress = self
        for _ in 0 ..< steps {
            progress.advance()
        }
        return progress
    }
}

/// Set by a task once it has begun, for `started`.
@MainActor
private final class EnteredFlag {
    var entered = false
}
