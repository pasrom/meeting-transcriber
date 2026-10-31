@testable import MeetingTranscriber
import XCTest

/// Where the speaker-naming paths read and write once the output folder setting
/// has moved away from the folder a job recorded.
///
/// Every test here gives the session a current folder that exists but holds
/// nothing, and the job one or two recorded folders that hold its files. A path
/// that resolved from the session's folder instead of the job's then finds
/// nothing, and a path that trusted the newest recorded folder without probing
/// finds the empty one.
@MainActor
final class NamingSidecarFolderTests: XCTestCase {
    private let slug = "standup_abcd1234"

    /// One speaker with an embedding, so a pass has something to name.
    private static let oneSpeaker = DiarizationResult(
        segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
        speakingTimes: ["SPEAKER_0": 5],
        autoNames: [:],
        embeddings: ["SPEAKER_0": [1, 0, 0]],
    )

    // MARK: - Late re-diarization

    /// The re-run reads each file from the newest recorded folder that holds
    /// it, writes its fresh naming data beside the audio, and records that
    /// folder. Resolved from the session's folder, the re-run was refused as
    /// "audio missing" on a job whose files were all present.
    ///
    /// The mix sits in both recorded folders and the cached segments only in
    /// the older one, because stage 3 moves them independently: the audio has
    /// to come from the newest copy, and the segments from wherever they are
    /// rather than from the folder the audio was found in.
    func testALateRerunReadsEachFileFromTheNewestRecordedFolderHoldingIt() async throws {
        let arrangement = try makeRerunArrangement()
        try writeMixAndSegments(in: arrangement.older)
        let newestMix = sidecar(SpeakerNamingStore.mixSuffix, in: arrangement.newest)
        try Data([0]).write(to: newestMix)

        let refusal = arrangement.session.completeSpeakerNaming(
            jobID: arrangement.job.id, result: .rerun(2), source: .dialog,
        )
        await waitForRerun(arrangement)

        XCTAssertNil(refusal, "the audio is in a folder the job recorded")
        XCTAssertEqual(
            arrangement.diarizer.receivedAudioPaths.map(\.standardizedFileURL.path),
            [newestMix.standardizedFileURL.path],
        )
        XCTAssertEqual(
            arrangement.delegate.renderedSegmentCounts, [1],
            "the transcript is rebuilt from the cached segments in the older folder",
        )
        let namingJSON = sidecar(SpeakerNamingStore.namingJSONSuffix, in: arrangement.newest)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: namingJSON.path),
            "the fresh naming data goes beside the audio it describes",
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sidecar(SpeakerNamingStore.namingJSONSuffix, in: arrangement.current).path,
        ))
        XCTAssertEqual(
            arrangement.delegate.recordedSidecarDirs.map { $0?.standardizedFileURL.path },
            [arrangement.newest.standardizedFileURL.path],
            "the folder the write landed in is recorded",
        )
    }

    /// A re-run whose save did not land records no folder: the read trusts the
    /// recorded order to find the newest payload, and a folder that received
    /// nothing would take the front of it.
    func testALateRerunWhoseSaveFailedRecordsNoFolder() async throws {
        let arrangement = try makeRerunArrangement()
        try writeMixAndSegments(in: arrangement.older)
        // A non-empty folder where the naming file goes, so the atomic write
        // cannot replace it.
        let blocker = sidecar(SpeakerNamingStore.namingJSONSuffix, in: arrangement.older)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data([0]).write(to: blocker.appendingPathComponent("keep"))

        arrangement.session.completeSpeakerNaming(
            jobID: arrangement.job.id, result: .rerun(2), source: .dialog,
        )
        await waitForRerun(arrangement)

        XCTAssertEqual(arrangement.diarizer.runCount, 1, "test premise: the re-run ran")
        XCTAssertTrue(
            arrangement.delegate.warnings.contains { $0.message.contains("could not be persisted") },
            "test premise: the save failed",
        )
        XCTAssertEqual(arrangement.delegate.recordedSidecarDirs, [nil])
    }

    /// A dual-source re-run opens the two tracks, so it probes for those and
    /// not for the mix: stage 3 moves the mix and the tracks independently, and
    /// a folder holding only the mix has nothing this run can diarize.
    func testADualSourceRerunReadsTheTracksFromTheFolderThatHoldsThem() async throws {
        let arrangement = try makeRerunArrangement(isDualSource: true)
        let appTrack = sidecar(SpeakerNamingStore.appTrackSuffix, in: arrangement.older)
        try Data([0]).write(to: appTrack)
        try Data([0]).write(to: sidecar(SpeakerNamingStore.micTrackSuffix, in: arrangement.older))
        // The newest folder holds the mix alone.
        try Data([0]).write(to: sidecar(SpeakerNamingStore.mixSuffix, in: arrangement.newest))

        arrangement.session.completeSpeakerNaming(
            jobID: arrangement.job.id, result: .rerun(2), source: .dialog,
        )
        await waitForRerun(arrangement)

        XCTAssertEqual(
            arrangement.delegate.dualTrackAppPaths.map(\.standardizedFileURL.path),
            [appTrack.standardizedFileURL.path],
        )
    }

    // MARK: - Protocol beside its transcript

    /// Skipping accepts the auto-names, and the protocol made from them goes
    /// beside the transcript, not under the folder the setting points at now.
    func testSkippingWritesTheProtocolBesideTheTranscript() async throws {
        let arrangement = try makeProtocolArrangement()

        arrangement.session.completeSpeakerNaming(
            jobID: arrangement.job.id, result: .skipped, source: .dialog,
        )
        await waitFor(arrangement.delegate.jobs[arrangement.job.id]?.state == .done, timeout: .seconds(2))

        XCTAssertEqual(
            arrangement.delegate.generateProtocolCalls.map(\.protocolsDir.standardizedFileURL.path),
            [arrangement.transcriptDir.standardizedFileURL.path],
        )
    }

    /// The day-old auto-accept takes the same path, and the same folder.
    func testTheStaleAutoAcceptWritesTheProtocolBesideTheTranscript() async throws {
        let arrangement = try makeProtocolArrangement()
        var stale = arrangement.job
        stale.namingStartedAt = Date(timeIntervalSinceNow: -2 * 86400)
        arrangement.delegate.jobs[stale.id] = stale

        arrangement.session.cleanupStalePending(pendingJobs: [stale])
        await waitFor(arrangement.delegate.jobs[stale.id]?.state == .done, timeout: .seconds(2))

        XCTAssertEqual(
            arrangement.delegate.generateProtocolCalls.map(\.protocolsDir.standardizedFileURL.path),
            [arrangement.transcriptDir.standardizedFileURL.path],
        )
    }

    // MARK: - First pass

    /// The first pass records the folder it saved to, and only when the save
    /// landed. The queue's side, which records exactly what it is handed, is
    /// pinned in `PipelineQueueTests`; this is the half that decides what to
    /// hand it.
    func testTheFirstPassRecordsItsFolderOnlyWhenTheSaveLanded() throws {
        let writable = try makeTempDirectory(prefix: "FirstPassWritable")
        // A regular file where the store wants its folder.
        let blocked = try makeTempDirectory(prefix: "FirstPassBlocked").appendingPathComponent("a-file")
        try Data([0]).write(to: blocked)

        XCTAssertEqual(
            try recordedFoldersOfFirstPass(writingTo: writable).map { $0?.standardizedFileURL.path },
            [writable.standardizedFileURL.path],
        )
        XCTAssertEqual(try recordedFoldersOfFirstPass(writingTo: blocked), [nil])
    }

    // MARK: - Arrangement

    private struct RerunArrangement {
        let session: SpeakerNamingSession
        let delegate: NamingSessionMockDelegate
        let diarizer: MockDiarization
        let job: PipelineJob
        /// Recorded first.
        let older: URL
        /// Recorded last, so the order alone would point here.
        let newest: URL
        /// The folder the session writes to now. Exists, holds nothing.
        let current: URL
    }

    private func makeRerunArrangement(isDualSource: Bool = false) throws -> RerunArrangement {
        let older = try makeTempDirectory(prefix: "RerunOlder")
        let newest = try makeTempDirectory(prefix: "RerunNewest")
        let current = try makeTempDirectory(prefix: "RerunCurrent")
        _ = try makeRecordingsDir(in: older)
        _ = try makeRecordingsDir(in: newest)
        _ = try makeRecordingsDir(in: current)

        let diarizer = MockDiarization()
        diarizer.resultToReturn = Self.oneSpeaker
        let session = NamingSessionFixture.session(outputDir: current, diarizer: diarizer)
        let delegate = NamingSessionMockDelegate()
        session.delegate = delegate

        let transcriptPath = try writeTranscript(in: older.appendingPathComponent("protocols"))
        var job = NamingSessionFixture.pendingJob(namingSlug: slug, transcriptPath: transcriptPath)
        job.recordSidecarOutputDir(older)
        job.recordSidecarOutputDir(newest)
        delegate.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = isDualSource
            ? NamingSessionFixture.dualTrackNamingData(jobID: job.id)
            : NamingSessionFixture.namingData(jobID: job.id)

        return RerunArrangement(
            session: session, delegate: delegate, diarizer: diarizer, job: job,
            older: older, newest: newest, current: current,
        )
    }

    /// Until the re-run's task has finished and handed the job back.
    private func waitForRerun(_ arrangement: RerunArrangement) async {
        await waitFor(
            arrangement.session.lateWork[arrangement.job.id] == nil
                && arrangement.delegate.jobs[arrangement.job.id]?.state == .speakerNamingPending,
            timeout: .seconds(5),
        )
    }

    /// The mix a single-source re-run opens and one cached transcript segment.
    private func writeMixAndSegments(in outputDir: URL) throws {
        try Data([0]).write(to: sidecar(SpeakerNamingStore.mixSuffix, in: outputDir))
        try JSONEncoder().encode([TimestampedSegment(start: 0, end: 5, text: "hello")])
            .write(to: sidecar(SpeakerNamingStore.segmentsSuffix, in: outputDir))
    }

    /// A one-line transcript at `<dir>/standup.txt`.
    private func writeTranscript(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("standup.txt")
        try "[00:00] SPEAKER_0: hello".write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    /// This job's sidecar with `suffix` under `outputDir`.
    private func sidecar(_ suffix: String, in outputDir: URL) -> URL {
        outputDir.appendingPathComponent("recordings/\(slug)\(suffix)")
    }

    private struct ProtocolArrangement {
        let session: SpeakerNamingSession
        let delegate: NamingSessionMockDelegate
        let job: PipelineJob
        let transcriptDir: URL
    }

    /// A pending job in a session that writes to another folder and can
    /// generate a protocol. The transcript sits in a folder of its own, under
    /// neither the folder the job recorded nor the session's, so "beside the
    /// transcript" cannot be mistaken for "under some output folder's
    /// `protocols`".
    private func makeProtocolArrangement() throws -> ProtocolArrangement {
        let recorded = try makeTempDirectory(prefix: "ProtocolRecorded")
        let current = try makeTempDirectory(prefix: "ProtocolCurrent")
        let transcriptDir = try makeTempDirectory(prefix: "ProtocolTranscript")
        let transcriptPath = try writeTranscript(in: transcriptDir)

        let session = NamingSessionFixture.session(outputDir: current) { MockProtocolGen() }
        let delegate = NamingSessionMockDelegate()
        session.delegate = delegate
        var job = NamingSessionFixture.pendingJob(namingSlug: slug, transcriptPath: transcriptPath)
        job.recordSidecarOutputDir(recorded)
        delegate.jobs[job.id] = job
        session.speakerNamingDataByJob[job.id] = NamingSessionFixture.namingData(jobID: job.id)
        return ProtocolArrangement(session: session, delegate: delegate, job: job, transcriptDir: transcriptDir)
    }

    /// Runs the first pass's naming stage writing to `outputDir` and returns
    /// what each of its metadata calls told the queue it wrote to. The session
    /// gets a folder of its own, so the folder recorded can only be the one
    /// the stage was handed.
    private func recordedFoldersOfFirstPass(writingTo outputDir: URL) throws -> [URL?] {
        let session = try NamingSessionFixture.session(outputDir: makeTempDirectory(prefix: "FirstPassSession"))
        let delegate = NamingSessionMockDelegate()
        session.delegate = delegate
        let job = NamingSessionFixture.pendingJob(namingSlug: nil, transcriptPath: nil)
        delegate.jobs[job.id] = job

        _ = session.resolveSpeakerNames(
            diarization: Self.oneSpeaker,
            job: (jobID: job.id, title: "Standup", slug: slug, participants: []),
            diarizeProcess: MockDiarization(),
            isDualSource: false, outputDir: outputDir,
        )

        return delegate.recordedSidecarDirs
    }
}
