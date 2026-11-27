@testable import MeetingTranscriber
import os
import XCTest

/// The compactor in a queue: a finished job's tracks become FLAC, every copy
/// is listed before it exists, the WAV goes last, and whatever happens during
/// the encode (a rename, a re-import, a cancel, a failure) leaves no file
/// under a track name that the registry does not list.
@MainActor
final class RecordingCompactionTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var fixture: RetentionQueueFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try RetentionQueueFixture(tmpDir: makeTempDirectory(prefix: "recording_compaction"))
        // Off, so the tracks stay for the compactor; tests that need a due
        // pass switch it on.
        fixture.enabled = false
    }

    override func tearDown() async throws {
        fixture = nil
        try await super.tearDown()
    }

    private var recordings: URL {
        fixture.recordingsDir
    }

    // MARK: - The wiring

    func testAFinishedJobsTracksBecomeFLACAndTheEntryListsExactlyThem() async throws {
        let compaction = fixture.makeCompaction()
        let queue = fixture.makeQueue(compaction: compaction)
        let job = try fixture.makeRecordedJob(pcm16: true)
        let original = try fixture.samples(of: [XCTUnwrap(job.mixPath), XCTUnwrap(job.appPath), XCTUnwrap(job.micPath)])
        try RecordingSidecar.writeTestRecordingSidecar(besideMix: XCTUnwrap(job.mixPath))
        queue.enqueue(job)
        await queue.processNext()
        let tracks = try fixture.relocatedTracks(of: queue.jobs.first)

        await waitForCompactionIdle(compaction)

        let copies = try tracks.map(compressedTrack)
        XCTAssertFalse(tracks.contains(where: CompactionDisk.exists), "a WAV survived")
        XCTAssertTrue(copies.allSatisfy(KeptRecordingCompressor.isNativeFLAC), "not every track is native FLAC")
        XCTAssertTrue(try fixture.samples(of: copies) == original, "a copy decodes to other samples")
        let sidecar = try XCTUnwrap(RecordingSidecar.recordingSidecarURL(besideMix: copies[0], extensions: RecordingFileSuffix.keptExtensions))
        XCTAssertEqual(fixture.listedNames, Set((copies + [sidecar]).map(\.lastPathComponent)))
        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(".") }, [], "a partial was left")
        XCTAssertEqual(CompactionDisk.entries(at: fixture.registryFile).first?.awaiting, [], "the mark stayed")
    }

    func testOffNothingIsMarkedAndNothingRuns() async throws {
        let runs = OSAllocatedUnfairLock(initialState: 0)
        let compaction = fixture.makeCompaction(isEnabled: { false }, report: { _ in runs.withLock { $0 += 1 } })
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)

        await queue.compactRecordings()

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists))
        XCTAssertFalse(try tracks.map(compressedTrack).contains(where: CompactionDisk.exists))
        XCTAssertEqual(CompactionDisk.entries(at: fixture.registryFile).first?.awaiting, [])
        XCTAssertEqual(runs.withLock { $0 }, 0, "a run looked at entries with the setting off")
    }

    /// Marked while the probe has not answered, so the launch run converts it.
    func testWithoutAnAnswerFromTheProbeTheEntryIsMarkedAndNotConverted() async throws {
        let compaction = fixture.makeCompaction(codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)

        await queue.compactRecordings()

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists))
        XCTAssertEqual(compaction.awaitingCount, 1)

        compaction.codecStatus = .available
        await queue.compactRecordings()
        XCTAssertTrue(try tracks.map(compressedTrack).allSatisfy(CompactionDisk.exists))
        XCTAssertEqual(compaction.awaitingCount, 0)
    }

    func testTheCopyIsListedBeforeItExists() async throws {
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let registryFile = fixture.registryFile
        let recordingRename: (URL, URL) throws -> Void = { from, to in
            let listed = CompactionDisk.listedNames(at: registryFile).contains(to.lastPathComponent)
            let present = CompactionDisk.exists(to)
            seen.withLock { $0.append("\(to.lastPathComponent) listed=\(listed) present=\(present)") }
            try RecordingCompaction.renameExclusive(from, to)
        }
        let compaction = fixture.makeCompaction(rename: recordingRename)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)

        await waitForCompactionIdle(compaction)

        let expected = try tracks.map { try "\(compressedTrack($0).lastPathComponent) listed=true present=false" }
        XCTAssertEqual(seen.withLock { $0 }, expected)
    }

    func testTheSourceIsRemovedOnlyAfterTheCopyIsListedAndInPlace() async throws {
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let registryFile = fixture.registryFile
        let steps = RecordingCompactionWorker.Steps.live.with(\.unlink) { wav in
            let copy = KeptRecordingCompressor.compressedURL(for: wav)
            let listed = CompactionDisk.listedNames(at: registryFile)
            let state = "copy listed=\(copy.map { listed.contains($0.lastPathComponent) } ?? false) "
                + "copy present=\(copy.map(CompactionDisk.exists) ?? false) source listed=\(listed.contains(wav.lastPathComponent))"
            seen.withLock { $0.append(state) }
            try RecordingFileDeleter.unlinkFile(wav)
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        _ = try await fixture.finishCompactableRecording(in: queue)

        await waitForCompactionIdle(compaction)

        XCTAssertEqual(seen.withLock { $0 }, Array(repeating: "copy listed=true copy present=true source listed=true", count: 3))
        XCTAssertEqual(fixture.listedNames.filter { $0.hasSuffix(".wav") }, [], "a removed WAV is still listed")
    }

    // MARK: - Races during the encode

    /// The AI-title rename moves the recording while its first track is being
    /// encoded. The copy under the old name must not be committed, nothing
    /// may be left that the registry does not list, and the run goes on with
    /// the tracks under the name the entry lists now.
    func testARenameToTheAITitleDuringTheEncodeLeavesNoUntrackedCopy() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (job, tracks) = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))
        let oldStem = try XCTUnwrap(RecordingFileSuffix.stripSuffix(from: tracks[0].lastPathComponent)?.stem)

        let newStem = queue.renameJobArtifacts(
            jobID: job.id, from: oldStem, titleSlug: "weekly_sync", protocolsDir: fixture.protocolsDir,
        )
        gate.open()
        await waitFor(!compaction.isRunning, timeout: .seconds(10))

        XCTAssertNotEqual(newStem, oldStem, "test premise: the rename ran")
        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(oldStem) }, [], "left under the old name")
        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(".") }, [], "a partial was left")
        XCTAssertEqual(fixture.unlistedRecordingFiles(), [], "unlisted files")
        XCTAssertTrue(
            RecordingFileSuffix.compressed.allSatisfy { CompactionDisk.exists(recordings.appendingPathComponent(newStem + $0)) },
            "the renamed tracks were not converted under their new name",
        )
        XCTAssertFalse(RecordingFileSuffix.all.contains { CompactionDisk.exists(recordings.appendingPathComponent(newStem + $0)) })
        XCTAssertEqual(compaction.awaitingCount, 0, "the run followed the rename and finished the recording")
    }

    /// The rename lands after the last copy took its name and before its WAV
    /// is removed and the sidecar rewritten. The WAV under the old name is not
    /// forgotten while its new name is listed, no sidecar is written under
    /// the old name, and the run finishes the moved track under the new one
    /// (checking its copy first), rewrites the sidecar and clears the mark.
    func testARenameBeforeTheLastUnlinkIsFollowedToTheEnd() async throws {
        var renamed: (queue: PipelineQueue, jobID: UUID, stem: String)?
        let compaction = fixture.makeCompaction(rename: { [weak self] from, to in
            try RecordingCompaction.renameExclusive(from, to)
            guard to.lastPathComponent.hasSuffix("_mic.flac"), let renamed, let self else { return }
            renamed.queue.renameJobArtifacts(
                jobID: renamed.jobID, from: renamed.stem, titleSlug: "weekly_sync", protocolsDir: fixture.protocolsDir,
            )
        }, codec: .unknown)
        let queue = fixture.makeQueue(compaction: compaction)
        let (job, tracks) = try await fixture.finishCompactableRecording(in: queue)
        let oldStem = try XCTUnwrap(RecordingFileSuffix.stripSuffix(from: tracks[0].lastPathComponent)?.stem)
        renamed = (queue, job.id, oldStem)
        compaction.codecStatus = .available

        await queue.compactRecordings()

        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(oldStem) }, [])
        XCTAssertEqual(fixture.unlistedRecordingFiles(), [], "unlisted files")
        XCTAssertEqual(compaction.awaitingCount, 0, "the run followed the rename and finished the recording")
        let names = CompactionDisk.recordingNames(in: recordings)
        XCTAssertEqual(names, ["weekly_sync_app.flac", "weekly_sync_mic.flac", "weekly_sync_mix.flac", "weekly_sync_recording.json"])
        let sidecar = try XCTUnwrap(RecordingSidecar.read(from: recordings.appendingPathComponent("weekly_sync_recording.json")))
        XCTAssertEqual([sidecar.files.mix, sidecar.files.app, sidecar.files.mic], ["weekly_sync_mix.flac", "weekly_sync_app.flac", "weekly_sync_mic.flac"])
        XCTAssertEqual(compaction.awaitingCount, 0)
    }

    /// A newer recording registered the same path during the encode, which
    /// takes it out of this entry while the file itself (as far as the size
    /// and time go) is unchanged. The entry no longer lists the WAV, so the
    /// copy must not be committed for it.
    func testAPathAnotherRecordingTookOverDuringTheEncodeIsNotConverted() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        let newer = UUID()
        fixture.retention.registry.register(jobID: newer, paths: [tracks[0]], root: fixture.output, recordedAt: Date())
        gate.open()
        await waitFor(!compaction.isRunning, timeout: .seconds(10))

        XCTAssertTrue(CompactionDisk.exists(tracks[0]), "the newer recording's file was removed")
        XCTAssertFalse(try CompactionDisk.exists(compressedTrack(tracks[0])), "a copy was committed for a path the entry gave up")
        XCTAssertEqual(fixture.unlistedRecordingFiles(), [], "unlisted files")
    }

    /// The WAV was rewritten in place during the encode: the copy is of what
    /// it held before, so it must not replace what it holds now.
    func testASourceChangedDuringTheEncodeIsNotReplaced() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        let rewritten = [Float](repeating: 0.25, count: 4 * AudioConstants.targetSampleRate)
        try AudioMixer.saveWAV(samples: rewritten, sampleRate: AudioConstants.targetSampleRate, url: tracks[0])
        gate.open()
        await waitFor(!compaction.isRunning, timeout: .seconds(10))

        XCTAssertTrue(CompactionDisk.exists(tracks[0]), "the rewritten WAV was removed for a copy of its old content")
        XCTAssertFalse(try CompactionDisk.exists(compressedTrack(tracks[0])))
    }

    /// A re-import of the same files takes them into use during the encode:
    /// the source stays, and no copy is committed.
    func testAReimportDuringTheEncodeKeepsTheSource() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        // Waiting, not run: what an import holds until its run is done.
        queue.jobs.append(PipelineJob(
            meetingTitle: "Reimport", appName: "File", mixPath: tracks[0], appPath: tracks[1], micPath: tracks[2], micDelay: 0,
        ))
        gate.open()
        await waitFor(!compaction.isRunning, timeout: .seconds(10))

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists), "a track the re-import reads was removed")
        XCTAssertFalse(try tracks.map(compressedTrack).contains(where: CompactionDisk.exists))
        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(".") }, [])
        XCTAssertEqual(compaction.awaitingCount, 1)
    }

    /// The run is cancelled while the encoder is busy, and the encoder ignores
    /// it and returns normally: the check after the await must stop the commit.
    func testCancelCommitsNothingEvenWhenTheEncoderIgnoresCancellation() async throws {
        let gate = StepGate()
        let steps = RecordingCompactionWorker.Steps.live.with(\.prepare) { source, partial in
            try KeptRecordingCompressor().prepare(source: source, partial: partial)
            await gate.pass()
        }
        let compaction = fixture.makeCompaction(steps: steps)
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        await waitFor(gate.reached == 1, timeout: .seconds(10))

        compaction.cancel()
        gate.open()
        await waitFor(!compaction.isRunning, timeout: .seconds(10))

        XCTAssertTrue(tracks.allSatisfy(CompactionDisk.exists))
        XCTAssertFalse(try tracks.map(compressedTrack).contains(where: CompactionDisk.exists))
        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings).filter { $0.hasPrefix(".") }, [], "the partial stayed")
        XCTAssertEqual(compaction.awaitingCount, 1, "a cancelled run keeps the mark")
    }

    // MARK: - The recording afterwards

    func testAFinishedJobNamesTheCompressedFilesAfterwards() async throws {
        let compaction = fixture.makeCompaction()
        let queue = fixture.makeQueue(compaction: compaction)
        let (job, tracks) = try await fixture.finishCompactableRecording(in: queue)

        await waitForCompactionIdle(compaction)

        let named = try fixture.relocatedTracks(of: queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(named, try tracks.map(compressedTrack))
        XCTAssertTrue(named.allSatisfy(CompactionDisk.exists))
        await queue.awaitSnapshotFlush()
        let saved = try XCTUnwrap(PipelineSnapshotStore.latestJobs(in: fixture.logDir)?.first { $0.id == job.id })
        XCTAssertEqual(try fixture.relocatedTracks(of: saved), named, "the snapshot names the WAVs")
    }

    func testTheSidecarNamesTheFilesAsTheyAreAndStillNamesAMix() async throws {
        let compaction = fixture.makeCompaction()
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)

        await waitForCompactionIdle(compaction)

        let mix = try compressedTrack(tracks[0])
        let sidecar = try XCTUnwrap(RecordingSidecar.read(from: XCTUnwrap(RecordingSidecar.recordingSidecarURL(
            besideMix: mix,
            extensions: RecordingFileSuffix.keptExtensions,
        ))))
        XCTAssertEqual([sidecar.files.mix, sidecar.files.app, sidecar.files.mic], try tracks.map { try compressedTrack($0).lastPathComponent })
        XCTAssertEqual(sidecar.version, RecordingSidecar.currentVersion)
        XCTAssertEqual(sidecar.micDelaySeconds, 0.25)
    }

    func testRetentionDeletesACompressedRecordingWhenDue() async throws {
        let compaction = fixture.makeCompaction()
        let queue = fixture.makeQueue(compaction: compaction)
        _ = try await fixture.finishCompactableRecording(in: queue)
        await waitForCompactionIdle(compaction)
        XCTAssertFalse(CompactionDisk.recordingNames(in: recordings).isEmpty, "test premise: the recording is there")

        fixture.enabled = true
        await queue.sweepRetainedRecordings()

        XCTAssertEqual(CompactionDisk.recordingNames(in: recordings), [])
        XCTAssertTrue(fixture.retention.registry.entries.isEmpty)
    }

    /// The compressed pair goes back through an import as one dual job with
    /// the recorded offset, and runs to the end.
    func testAReimportOfTheCompressedPairCompletesWithTheSidecarOffset() async throws {
        let compaction = fixture.makeCompaction()
        let queue = fixture.makeQueue(compaction: compaction)
        let (_, tracks) = try await fixture.finishCompactableRecording(in: queue)
        await waitForCompactionIdle(compaction)
        let controller = try makeIsolatedPipelineController(initialQueue: queue)

        let ids = try controller.enqueueFiles([compressedTrack(tracks[1]), compressedTrack(tracks[2])], autoSkipNaming: true)
        await queue.processNext()

        let id = try XCTUnwrap(ids.first)
        XCTAssertEqual(ids.count, 1, "the FLAC pair is one dual-source job")
        let reimported = try XCTUnwrap(queue.jobs.first { $0.id == id })
        XCTAssertEqual(reimported.micDelay, 0.25, "the offset from the sidecar")
        XCTAssertEqual(reimported.state, .done)
    }
}
