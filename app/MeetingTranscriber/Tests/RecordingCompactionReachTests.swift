@testable import MeetingTranscriber
import os
import XCTest

/// What the compactor does when the world moves under a run: the output
/// folder goes away, a later recording is renamed, the verified copy is
/// replaced, a cut-off run is resumed; and the exclusive rename on volumes
/// without `RENAME_EXCL`.
@MainActor
final class RecordingCompactionReachTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var fixture: RetentionQueueFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try RetentionQueueFixture(tmpDir: makeTempDirectory(prefix: "recording_compaction_reach"))
        fixture.enabled = false
    }

    override func tearDown() async throws {
        fixture = nil
        try await super.tearDown()
    }

    private var recordings: URL {
        fixture.recordingsDir
    }

    private func blockingFirstPrepare(_ gate: StepGate) -> RecordingCompactionWorker.Steps {
        RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
    }

    /// Two finished recordings, marked and not yet converted.
    private func twoMarkedRecordings(
        steps: RecordingCompactionWorker.Steps,
    ) async throws -> (RecordingCompaction, PipelineQueue, [(job: PipelineJob, tracks: [URL])]) {
        let compaction = fixture.makeCompaction(steps: steps, codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        let first = try await fixture.finishCompactableRecording(in: queue)
        let second = try await fixture.finishCompactableRecording(in: queue)
        XCTAssertEqual(compaction.awaitingCount, 2, "test premise: both marked")
        compaction.codecStatus = .available
        return (compaction, queue, [first, second])
    }

    /// The drive goes away while the first recording is encoded: every
    /// track then reads as gone, which is no reason to give up on either.
    func testARootThatVanishesMidRunKeepsTheMarks() async throws {
        let gate = StepGate()
        let (compaction, queue, _) = try await twoMarkedRecordings(steps: blockingFirstPrepare(gate))
        let run = Task { await queue.compactRecordings() }
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        try FileManager.default.moveItem(at: fixture.output, to: fixture.tmpDir.appendingPathComponent("unplugged"))
        gate.open()
        await run.value

        XCTAssertEqual(compaction.awaitingCount, 2)
    }

    /// No `recordings` folder under an output folder that is there: what a
    /// volume detached from a custom mount point looks like (the mount point
    /// stays as an empty folder), so the marks stay, as retention keeps such
    /// an entry.
    func testAMissingRecordingsFolderKeepsTheMarks() async throws {
        let (compaction, queue, _) = try await twoMarkedRecordings(steps: .live)
        try FileManager.default.moveItem(at: recordings, to: fixture.tmpDir.appendingPathComponent("detached"))

        await queue.compactRecordings()

        XCTAssertEqual(compaction.awaitingCount, 2)
    }

    /// The copy went away after the commit, before its WAV is removed: the
    /// WAV stays.
    func testAWAVIsNotRemovedWhenItsCopyIsGone() async throws {
        let steps = RecordingCompactionWorker.Steps.live.with(\.syncFolder) { folder in
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix("_mix.flac") {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)

        await waitFor(!compaction.isRunning, timeout: .seconds(10))
        await queue.compactRecordings()

        XCTAssertTrue(CompactionDisk.exists(tracks[0]), "the mix WAV went although its copy was gone")
        XCTAssertEqual(compaction.awaitingCount, 1)
    }

    /// The second recording is renamed while the first is encoded. The run
    /// reads each entry's tracks when it gets to it, so it converts the
    /// second under its new name and leaves nothing unlisted.
    func testARenameOfALaterRecordingDuringTheRunIsFollowed() async throws {
        let gate = StepGate()
        let (compaction, queue, recordingsMade) = try await twoMarkedRecordings(steps: blockingFirstPrepare(gate))
        let run = Task { await queue.compactRecordings() }
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        let second = recordingsMade[1]
        let oldStem = try XCTUnwrap(RecordingFileSuffix.stripSuffix(from: second.tracks[0].lastPathComponent)?.stem)
        let newStem = queue.renameJobArtifacts(
            jobID: second.job.id, from: oldStem, titleSlug: "renamed_meeting", protocolsDir: fixture.protocolsDir,
        )
        XCTAssertNotEqual(newStem, oldStem, "test premise: the rename ran")
        gate.open()
        await run.value

        XCTAssertTrue(
            RecordingFileSuffix.compressed.allSatisfy { CompactionDisk.exists(recordings.appendingPathComponent(newStem + $0)) },
            "the renamed recording was not converted under its new name",
        )
        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(oldStem) }, [])
        XCTAssertEqual(fixture.unlistedRecordingFiles(), [], "unlisted files")
        XCTAssertEqual(compaction.awaitingCount, 0)
    }

    /// The partial is replaced between its verify and the commit: the commit
    /// must not give a track name to a file nobody compared.
    func testAPartialReplacedAfterTheVerifyIsNotCommitted() async throws {
        let steps = RecordingCompactionWorker.Steps.live.with(\.identity) { partial in
            let verified = RecordingCompaction.liveIdentity(partial)
            // Another file put in its place, of the same content.
            let other = partial.deletingLastPathComponent().appendingPathComponent(".swap")
            try? FileManager.default.copyItem(at: partial, to: other)
            _ = try? FileManager.default.replaceItemAt(partial, withItemAt: other)
            return verified
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)

        await waitFor(!compaction.isRunning, timeout: .seconds(10))
        await queue.compactRecordings()

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists), "a WAV went for a copy nobody verified")
        XCTAssertFalse(try tracks.map(compressedTrack).contains(where: CompactionDisk.exists))
        XCTAssertEqual(compaction.awaitingCount, 1)
    }

    /// A cut-off run left the WAV and its copy both listed, with the job still
    /// naming the WAV. Finishing it points the job at the copy.
    func testResumingACutOffRunPointsTheJobAtTheCopy() async throws {
        let compaction = fixture.makeCompaction(codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        let (job, tracks) = try await fixture.finishCompactableRecording(in: queue)
        let copy = try compressedTrack(tracks[0])
        try KeptRecordingCompressor().prepare(source: tracks[0], partial: copy)
        fixture.retention.registry.register(jobID: job.id, paths: [copy], root: fixture.output, recordedAt: Date())
        compaction.codecStatus = .available

        await queue.compactRecordings()

        XCTAssertFalse(CompactionDisk.exists(tracks[0]), "test premise: the resume removed the WAV")
        XCTAssertEqual(queue.jobs.first { $0.id == job.id }?.mixPath, copy)
    }

    func testAJobWithNoEntryStartsNoRun() {
        let compaction = fixture.makeCompaction()

        XCTAssertFalse(compaction.markFinished(jobID: UUID(), root: fixture.output))
        XCTAssertEqual(compaction.awaitingCount, 0)
    }

    // MARK: - Exclusive rename without RENAME_EXCL

    private func files() throws -> (from: URL, to: URL) {
        let dir = try makeTempDirectory(prefix: "rename-exclusive")
        let from = dir.appendingPathComponent(".m_mix.partial.flac")
        try Data("copy".utf8).write(to: from)
        return (from, dir.appendingPathComponent("m_mix.flac"))
    }

    private var noExclusiveRename: RecordingCompaction.RenameCalls {
        var calls = RecordingCompaction.RenameCalls.live
        calls.renameExclusive = { _, _ in ENOTSUP }
        return calls
    }

    /// The hard link, not a check followed by a rename: only the link fails
    /// by itself on a name taken in between.
    func testWithoutRenameExclAHardLinkTakesTheName() throws {
        let renames = OSAllocatedUnfairLock(initialState: 0)
        var calls = noExclusiveRename
        let live = calls.rename
        calls.rename = { from, to in
            renames.withLock { $0 += 1 }
            return live(from, to)
        }
        let (from, to) = try files()

        try RecordingCompaction.renameExclusive(from, to, calls: calls)

        XCTAssertEqual(try Data(contentsOf: to), Data("copy".utf8))
        XCTAssertFalse(CompactionDisk.exists(from))
        XCTAssertEqual(renames.withLock { $0 }, 0, "a plain rename, where a link would have done")
    }

    func testWithoutRenameExclATakenNameIsNeverReplaced() throws {
        let (from, to) = try files()
        try Data("theirs".utf8).write(to: to)

        XCTAssertThrowsError(try RecordingCompaction.renameExclusive(from, to, calls: noExclusiveRename)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: to), Data("theirs".utf8))
        XCTAssertTrue(CompactionDisk.exists(from))
    }

    /// A link refused with any errno but "exists" means no hard links here,
    /// whichever errno the volume picks: on to the checked rename.
    func testALinkRefusedForAnyReasonButExistsFallsThrough() throws {
        var calls = noExclusiveRename
        calls.link = { _, _ in EOPNOTSUPP }
        let (from, to) = try files()

        try RecordingCompaction.renameExclusive(from, to, calls: calls)

        XCTAssertEqual(try Data(contentsOf: to), Data("copy".utf8))
    }

    /// A volume with neither (FAT, exFAT): the name is checked, and a plain
    /// rename runs only when it is free.
    func testWithoutHardLinksTheNameIsCheckedBeforeARename() throws {
        let renames = OSAllocatedUnfairLock(initialState: 0)
        var calls = noExclusiveRename
        calls.link = { _, _ in ENOTSUP }
        let live = calls.rename
        calls.rename = { from, to in
            renames.withLock { $0 += 1 }
            return live(from, to)
        }
        let (from, to) = try files()
        try Data("theirs".utf8).write(to: to)

        XCTAssertThrowsError(try RecordingCompaction.renameExclusive(from, to, calls: calls))
        XCTAssertEqual(renames.withLock { $0 }, 0, "renamed over a taken name")

        try FileManager.default.removeItem(at: to)
        try RecordingCompaction.renameExclusive(from, to, calls: calls)
        XCTAssertEqual(renames.withLock { $0 }, 1)
        XCTAssertEqual(try Data(contentsOf: to), Data("copy".utf8))
    }
}
