@testable import MeetingTranscriber
import XCTest

/// The queue's side of the retention setting: which relocations it records
/// and what a pass leaves alone. When outputs count as written is in
/// `PipelineQueueRetentionOutputTests`.
@MainActor
final class PipelineQueueRetentionTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var fixture: RetentionQueueFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try RetentionQueueFixture(tmpDir: makeTempDirectory(prefix: "queue_retention"))
    }

    override func tearDown() async throws {
        fixture = nil
        try await super.tearDown()
    }

    // MARK: - What gets recorded

    /// The registry is written whether fixture.retention is on or not, so switching it
    /// on later covers what was recorded while it was off.
    func testARelocatedRecordingIsRecordedWhileRetentionIsOff() async throws {
        fixture.enabled = false
        let queue = fixture.makeQueue()
        let job = try fixture.makeRecordedJob()
        queue.enqueue(job)
        await queue.processNext()

        let tracks = try fixture.relocatedTracks(of: queue.jobs.first)
        let entry = try XCTUnwrap(fixture.retention.registry.entries.first)
        XCTAssertEqual(entry.jobID, job.id)
        XCTAssertEqual(entry.paths.map(\.standardizedFileURL), tracks.map(\.standardizedFileURL))
        XCTAssertEqual(entry.root.standardizedFileURL, fixture.output.standardizedFileURL, "the root, not recordings/")
        XCTAssertEqual(entry.recordedAt, job.meetingStartTime, "days count from the recording date")
        XCTAssertNotNil(entry.eligibleAt)
        XCTAssertTrue(tracks.allSatisfy(fixture.exists))

        fixture.enabled = true
        await queue.sweepRetainedRecordings()
        XCTAssertFalse(tracks.contains(where: fixture.exists), "switched on later, the earlier recording is due")
    }

    /// The entry fixture.exists from the moment the audio moved, before the job
    /// finishes. A job parked for speaker naming is the visible case; a quit
    /// while the protocol is generated is the one it guards against.
    func testTheEntryIsWrittenWhenTheAudioMovesNotWhenTheJobFinishes() async throws {
        let queue = fixture.makeQueue(parksForNaming: true)
        let job = try fixture.makeRecordedJob()
        queue.enqueue(job)
        await queue.processNext()
        XCTAssertEqual(queue.jobs.first?.state, .speakerNamingPending)

        let entry = try XCTUnwrap(fixture.retention.registry.entries.first, "relocated audio must be recorded at once")
        XCTAssertEqual(entry.jobID, job.id)
        XCTAssertNil(entry.eligibleAt, "no protocol yet")

        await queue.sweepRetainedRecordings()
        XCTAssertTrue(
            try fixture.relocatedTracks(of: queue.jobs.first).allSatisfy(fixture.exists),
            "a recording waiting on speaker naming stays put",
        )
    }

    func testAFinishedRecordingIsDeletedAndItsOutputsKept() async throws {
        let queue = fixture.makeQueue()
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        let finished = try XCTUnwrap(queue.jobs.first)
        let tracks = try fixture.relocatedTracks(of: finished)

        await queue.sweepRetainedRecordings()

        XCTAssertFalse(tracks.contains(where: fixture.exists))
        XCTAssertTrue(try fixture.exists(XCTUnwrap(finished.protocolPath)))
        XCTAssertTrue(try fixture.exists(XCTUnwrap(finished.transcriptPath)))
        XCTAssertTrue(fixture.retention.registry.entries.isEmpty)
    }

    /// Reaching `.done` starts a pass by itself; nobody has to call one.
    func testFinishingAJobStartsAPass() async throws {
        let queue = fixture.makeQueue()
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        let tracks = try fixture.relocatedTracks(of: queue.jobs.first)

        await waitFor({ !tracks.contains(where: self.fixture.exists) }, timeout: .seconds(3))
        XCTAssertFalse(tracks.contains(where: fixture.exists))
    }

    /// A file the user picked is never recorded, so no setting can delete it.
    func testAnImportIsNeverRecorded() async throws {
        let picked = fixture.tmpDir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let queue = fixture.makeQueue()
        let job = try fixture.makeRecordedJob(in: picked)
        queue.enqueue(job)
        await queue.processNext()
        await queue.sweepRetainedRecordings()

        XCTAssertTrue(fixture.retention.registry.entries.isEmpty)
        XCTAssertTrue(try fixture.relocatedTracks(of: job).allSatisfy(fixture.exists))
    }

    // MARK: - What a pass leaves alone

    /// A running job holding only the app track of a due recording keeps all
    /// three tracks: the in-flight claims name mix files only, so the
    /// protection has to come from every track of every unfinished job.
    func testAnUnfinishedJobHoldingOneTrackKeepsTheWholeRecording() async throws {
        fixture.enabled = false
        let queue = fixture.makeQueue()
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        let tracks = try fixture.relocatedTracks(of: queue.jobs.first)

        var reader = PipelineJob(
            meetingTitle: "Re-run", appName: "File",
            mixPath: fixture.tmpDir.appendingPathComponent("elsewhere_mix.wav"),
            appPath: tracks[1], micPath: nil, micDelay: 0,
        )
        reader.state = .transcribing
        queue.insertJobForTesting(reader)

        fixture.enabled = true
        await queue.sweepRetainedRecordings()
        XCTAssertTrue(tracks.allSatisfy(fixture.exists), "one track in use keeps the whole recording")
    }

    /// The AI-title rename moves the audio after it was recorded; the entry
    /// follows, so the renamed files are still deleted when due.
    func testARenamedRecordingIsStillDeleted() async throws {
        let generator = MockProtocolGen()
        generator.headingTitle = "Sprint Planning"
        let queue = fixture.makeQueue(protocolGen: generator)
        var job = try fixture.makeRecordedJob()
        job.useAITitleForFilenames = true
        queue.enqueue(job)
        await queue.processNext()
        let tracks = try fixture.relocatedTracks(of: queue.jobs.first)
        XCTAssertEqual(tracks.first?.lastPathComponent, "sprint_planning_mix.wav")
        XCTAssertEqual(
            fixture.retention.registry.entries.first?.paths.map(\.standardizedFileURL),
            tracks.map(\.standardizedFileURL),
        )

        await queue.sweepRetainedRecordings()

        XCTAssertFalse(tracks.contains(where: fixture.exists))
    }

    // MARK: - Review findings

    /// A destination that already holds a file whose source is gone was not
    /// shown to be this job's move: it may be a file the user or a sync tool
    /// put there. It is left unrecorded, so fixture.retention never deletes it.
    func testAnExistingDestinationWithoutItsSourceIsNotClaimed() async throws {
        let queue = fixture.makeQueue()
        let job = try fixture.makeRecordedJob()
        let app = try XCTUnwrap(job.appPath)
        let slug = PipelineQueue.namingSlug(title: job.meetingTitle, jobID: job.id, startTime: job.artifactStartTime)
        try FileManager.default.createDirectory(at: fixture.recordingsDir, withIntermediateDirectories: true)
        let foreign = fixture.recordingsDir.appendingPathComponent("\(slug)\(RecordingFileSuffix.app)")
        try FileManager.default.moveItem(at: app, to: foreign)
        let foreignContent = Data("the user's own file".utf8)
        try foreignContent.write(to: foreign)
        queue.enqueue(job)
        await queue.processNext()
        await queue.sweepRetainedRecordings()

        let listed = Set(fixture.retention.registry.entries.flatMap(\.paths).map(RecordingRetentionPolicy.pathKey))
        XCTAssertFalse(listed.contains(RecordingRetentionPolicy.pathKey(foreign)), "a file it did not move is not claimed")
        XCTAssertEqual(try? Data(contentsOf: foreign), foreignContent, "and a pass leaves it alone")
    }

    /// When the AI-title rename fails and moving an earlier file back fails
    /// too, that file stays under the new name; the registry has to name it
    /// there, or the cleaner would forget it and it would never be deleted.
    func testAFailedRenameRollbackLeavesTheRegistryWhereTheFilesAre() async throws {
        fixture.enabled = false // about where the registry points; no pass may delete meanwhile
        let generator = MockProtocolGen()
        generator.headingTitle = "Sprint Planning"
        let queue = fixture.makeQueue(protocolGen: generator) { from, to in
            let name = from.lastPathComponent
            if name.hasPrefix("sprint_planning"), name.hasSuffix(RecordingFileSuffix.mix) {
                throw CocoaError(.fileWriteNoPermission) // the undo of the mix
            }
            if !name.hasPrefix("sprint_planning"), name.hasSuffix(RecordingFileSuffix.mic) {
                throw CocoaError(.fileWriteNoPermission) // the forward move of the mic
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
        var job = try fixture.makeRecordedJob()
        job.useAITitleForFilenames = true
        queue.enqueue(job)
        await queue.processNext()

        let listed = try XCTUnwrap(fixture.retention.registry.entries.first).paths
        XCTAssertTrue(listed.allSatisfy(fixture.exists), "every listed path must exist: \(listed.map(\.lastPathComponent))")
        XCTAssertTrue(listed.contains { $0.lastPathComponent == "sprint_planning_mix.wav" })
    }
}
