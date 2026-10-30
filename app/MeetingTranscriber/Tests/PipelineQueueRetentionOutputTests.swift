@testable import MeetingTranscriber
import XCTest

/// When a job's output counts as written, so its recording may go: which
/// ways of finishing mark it, and which keep the audio.
@MainActor
final class PipelineQueueRetentionOutputTests: XCTestCase {
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

    /// A failed protocol run still ends in `.done` (the transcript is saved), but
    /// the audio stays, so the run can be retried.
    func testAFailedProtocolKeepsTheAudio() async throws {
        let failing = MockProtocolGen()
        failing.shouldThrow = true
        let queue = fixture.makeQueue(protocolGen: failing)
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        XCTAssertEqual(queue.jobs.first?.state, .done)

        await queue.sweepRetainedRecordings()

        XCTAssertNil(fixture.retention.registry.entries.first?.eligibleAt)
        XCTAssertTrue(try fixture.relocatedTracks(of: queue.jobs.first).allSatisfy(fixture.exists))
    }

    /// A provider switched off while its call is running must not turn the
    /// failed run into a "no provider" run: the transcript only counts for a
    /// job that never had a generator.
    func testAProviderSwitchedOffDuringAFailedRunKeepsTheAudio() async throws {
        let failing = MockProtocolGen()
        failing.shouldThrow = true
        let provider = RetentionProviderSwitch(generator: failing)
        failing.onGenerate = { provider.generator = nil }
        let queue = fixture.makeQueue(provider: provider)
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        XCTAssertTrue(failing.generateCalled)
        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertNil(queue.jobs.first?.protocolPath)

        await queue.sweepRetainedRecordings()

        let entry = try XCTUnwrap(fixture.retention.registry.entries.first, "the relocated audio is recorded")
        XCTAssertNil(entry.eligibleAt)
        XCTAssertTrue(try fixture.relocatedTracks(of: queue.jobs.first).allSatisfy(fixture.exists))
    }

    /// With no protocol provider configured the transcript is the only fixture.output,
    /// so a saved transcript is what "written" means.
    func testWithoutAProtocolProviderTheSavedTranscriptCounts() async throws {
        let queue = fixture.makeQueue(protocolGen: nil)
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        let finished = try XCTUnwrap(queue.jobs.first)
        XCTAssertNil(finished.protocolPath)
        XCTAssertNotNil(finished.transcriptPath)

        await queue.sweepRetainedRecordings()

        XCTAssertFalse(try fixture.relocatedTracks(of: finished).contains(where: fixture.exists))
    }

    /// A Notion export that replaces the local Markdown leaves the page as the
    /// fixture.output. Its local backup is gone by design, so that must not read as
    /// "the user deleted the protocol" and keep the audio for good.
    func testANotionOnlyExportStillLetsTheRecordingGo() async throws {
        fixture.days = 1
        fixture.enabled = false // no pass before the export has finished
        let exporter = RetentionNotionExporter(fail: false)
        let queue = fixture.makeQueue(notion: NotionExportConfiguration(
            exporter: exporter, databaseID: "database-1", skipLocalMarkdown: true,
        ))
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        await queue.awaitNotionExports()
        let finished = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(finished.notionExportStatus, .completed)
        XCTAssertNil(finished.protocolPath, "the local backup was removed after the export")
        let tracks = try fixture.relocatedTracks(of: finished)

        fixture.enabled = true
        await queue.sweepRetainedRecordings()

        XCTAssertFalse(tracks.contains(where: fixture.exists), "the Notion page is the fixture.output")
    }

    /// A Notion export that failed keeps the local Markdown, which stays the
    /// output: deleting it afterwards still keeps the audio.
    func testAFailedNotionExportKeepsTheLocalProtocolAsTheOutput() async throws {
        fixture.enabled = false
        let exporter = RetentionNotionExporter(fail: true)
        let queue = fixture.makeQueue(notion: NotionExportConfiguration(
            exporter: exporter, databaseID: "database-1", skipLocalMarkdown: true,
        ))
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        await queue.awaitNotionExports()
        let finished = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(finished.notionExportStatus, .failed)
        try FileManager.default.removeItem(at: XCTUnwrap(finished.protocolPath))

        fixture.enabled = true
        await queue.sweepRetainedRecordings()

        XCTAssertTrue(try fixture.relocatedTracks(of: finished).allSatisfy(fixture.exists))
    }

    /// A job whose naming data was lost across a restart is finished without
    /// the speakers ever being confirmed. With no protocol provider its
    /// transcript is the unconfirmed draft, which does not count as written.
    func testAJobFinishedBecauseItsNamingDataWasLostIsNotEligible() async throws {
        let queue = fixture.makeQueue(protocolGen: nil, parksForNaming: true)
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        let parked = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(parked.state, .speakerNamingPending)
        await queue.awaitSnapshotFlush()
        let slug = try XCTUnwrap(parked.namingSlug)
        try FileManager.default.removeItem(
            at: fixture.recordingsDir.appendingPathComponent("\(slug)\(SpeakerNamingStore.namingJSONSuffix)"),
        )

        let restored = fixture.makeQueue(protocolGen: nil, parksForNaming: true)
        restored.loadSnapshot()
        await restored.awaitProcessing()

        XCTAssertEqual(restored.jobs.first?.state, .done)
        XCTAssertNil(fixture.retention.registry.entries.first?.eligibleAt, "an unconfirmed draft is not the fixture.output")
    }

    /// A confirm that cannot rewrite the transcript leaves the auto-names in it
    /// and still finishes the job. With no protocol provider that transcript is
    /// the unconfirmed draft, so it does not make the job eligible either.
    func testALateConfirmThatCannotRewriteTheTranscriptIsNotEligible() async throws {
        let queue = fixture.makeQueue(protocolGen: nil, parksForNaming: true)
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        let parked = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(parked.state, .speakerNamingPending)
        let transcriptFolder = try XCTUnwrap(parked.transcriptPath).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: transcriptFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transcriptFolder.path) }
        let label = try XCTUnwrap(queue.naming.speakerNamingDataByJob[parked.id]?.mapping.keys.first)

        queue.completeSpeakerNaming(jobID: parked.id, result: .confirmed([label: "Speaker A"]), source: .dialog)
        await waitFor({ queue.jobs.first?.state == .done }, timeout: .seconds(3))

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertTrue(
            queue.jobs.first?.warnings.contains("Protocol not generated: rewriting the transcript with the speaker names failed")
                ?? false,
            "the rewrite must actually have failed for this test to say anything",
        )
        await queue.sweepRetainedRecordings()
        XCTAssertTrue(try fixture.relocatedTracks(of: queue.jobs.first).allSatisfy(fixture.exists))
        let entry = try XCTUnwrap(fixture.retention.registry.entries.first, "the relocated audio is recorded")
        XCTAssertNil(entry.eligibleAt, "the transcript still carries the auto-names")
    }

    /// The fixture.output has to exist when it is reported written, not just be named.
    func testAnOutputThatIsNotOnDiskDoesNotMakeTheJobEligible() throws {
        let queue = fixture.makeQueue(protocolGen: nil)
        var job = try fixture.makeRecordedJob()
        job.transcriptPath = fixture.protocolsDir.appendingPathComponent("never_written.txt")
        job.state = .generatingProtocol
        queue.insertJobForTesting(job)
        try fixture.retention.registry.register(
            jobID: job.id, paths: fixture.relocatedTracks(of: job), root: fixture.output, recordedAt: job.artifactStartTime,
        )

        queue.markOutputWritten(jobID: job.id, output: job.transcriptPath)

        let entry = try XCTUnwrap(fixture.retention.registry.entries.first)
        XCTAssertNil(entry.eligibleAt)
    }

    /// A confirm whose transcript cannot be read applies no names either, so
    /// the transcript left behind is still the auto-named draft.
    func testALateConfirmWithAnUnreadableTranscriptIsNotEligible() async throws {
        let queue = fixture.makeQueue(protocolGen: nil, parksForNaming: true)
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        let parked = try XCTUnwrap(queue.jobs.first)
        let transcript = try XCTUnwrap(parked.transcriptPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: transcript.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path) }
        let label = try XCTUnwrap(queue.naming.speakerNamingDataByJob[parked.id]?.mapping.keys.first)

        queue.completeSpeakerNaming(jobID: parked.id, result: .confirmed([label: "Speaker A"]), source: .dialog)
        await waitFor({ queue.jobs.first?.state == .done }, timeout: .seconds(3))

        XCTAssertEqual(queue.jobs.first?.state, .done)
        XCTAssertTrue(
            queue.jobs.first?.warnings.contains(SpeakerNamingSession.missingTranscriptWarning) ?? false,
            "the read must actually have failed for this test to say anything",
        )
        await queue.sweepRetainedRecordings()
        XCTAssertTrue(try fixture.relocatedTracks(of: queue.jobs.first).allSatisfy(fixture.exists))
    }

    /// Accepting the auto-names (a skip, or the naming wait running out) makes
    /// them the final names. With no provider the transcript carrying them is
    /// the fixture.output, so the recording may go.
    func testSkippingTheNamingWithoutAProviderLetsTheRecordingGo() async throws {
        let queue = fixture.makeQueue(protocolGen: nil, parksForNaming: true)
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        let parked = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(parked.state, .speakerNamingPending)
        let tracks = try fixture.relocatedTracks(of: parked)

        queue.completeSpeakerNaming(jobID: parked.id, result: .skipped, source: .dialog)
        await waitFor({ queue.jobs.first?.state == .done }, timeout: .seconds(3))
        await queue.sweepRetainedRecordings()

        XCTAssertFalse(tracks.contains(where: fixture.exists))
    }

    /// A job quit during its protocol call was a run with a provider. Resumed
    /// after the provider was switched off, it still has no protocol, so its
    /// transcript does not stand in for one.
    func testAJobResumedWithoutTheProviderItWasStartedWithKeepsTheAudio() async throws {
        let queue = fixture.makeQueue()
        var job = try fixture.makeRecordedJob()
        let transcript = fixture.protocolsDir.appendingPathComponent("\(job.id.uuidString.prefix(8))_transcript.txt")
        try FileManager.default.createDirectory(at: fixture.protocolsDir, withIntermediateDirectories: true)
        try "[00:00] Speaker A: hello".write(to: transcript, atomically: true, encoding: .utf8)
        job.transcriptPath = transcript
        job.namingSlug = String(job.id.uuidString.prefix(8)) // what a protocol-only resume needs
        job.state = .generatingProtocol
        queue.insertJobForTesting(job)
        try fixture.retention.registry.register(
            jobID: job.id, paths: fixture.relocatedTracks(of: job), root: fixture.output, recordedAt: job.artifactStartTime,
        )
        queue.saveSnapshot()
        await queue.awaitSnapshotFlush()

        let restored = fixture.makeQueue(protocolGen: nil)
        restored.loadSnapshot()
        await restored.awaitProcessing()

        XCTAssertEqual(restored.jobs.first?.state, .done)
        XCTAssertNil(restored.jobs.first?.protocolPath)
        // The tracks sit in fixture.staging here, out of the cleaner's reach, so the
        // entry's state is what says whether the recording may go.
        let entry = try XCTUnwrap(fixture.retention.registry.entries.first, "the relocated audio is recorded")
        XCTAssertNil(entry.eligibleAt, "the run was started with a provider")
    }

    /// A job killed after writing its protocol but before finishing is
    /// finished by the restore without a second call. Its protocol is on
    /// disk, so it counts as written.
    func testAJobFinishedByTheRestoreWithItsProtocolWrittenLetsTheRecordingGo() async throws {
        let queue = fixture.makeQueue()
        var job = try fixture.makeRecordedJob()
        let stem = String(job.id.uuidString.prefix(8))
        try FileManager.default.createDirectory(at: fixture.protocolsDir, withIntermediateDirectories: true)
        let transcript = fixture.protocolsDir.appendingPathComponent("\(stem)_transcript.txt")
        let protocolFile = fixture.protocolsDir.appendingPathComponent("\(stem).md")
        try "[00:00] Speaker A: hello".write(to: transcript, atomically: true, encoding: .utf8)
        try "# Meeting Protocol".write(to: protocolFile, atomically: true, encoding: .utf8)
        job.transcriptPath = transcript
        job.protocolPath = protocolFile
        job.namingSlug = stem
        job.state = .generatingProtocol
        queue.insertJobForTesting(job)
        try fixture.retention.registry.register(
            jobID: job.id, paths: fixture.relocatedTracks(of: job), root: fixture.output, recordedAt: job.artifactStartTime,
        )
        queue.saveSnapshot()
        await queue.awaitSnapshotFlush()

        let restored = fixture.makeQueue()
        restored.loadSnapshot()
        await restored.awaitProcessing()
        XCTAssertEqual(restored.jobs.first?.state, .done)
        // The tracks sit in fixture.staging here, out of the cleaner's reach, so the
        // entry's state is what says whether the recording may go.
        let entry = try XCTUnwrap(fixture.retention.registry.entries.first)
        XCTAssertEqual(entry.outputPath?.standardizedFileURL, protocolFile.standardizedFileURL)
        XCTAssertNotNil(entry.eligibleAt, "the protocol on disk is the fixture.output")
    }

    /// An empty fixture.output file is not a written fixture.output.
    func testAnEmptyOutputDoesNotMakeTheJobEligible() throws {
        let queue = fixture.makeQueue(protocolGen: nil)
        var job = try fixture.makeRecordedJob()
        let transcript = fixture.protocolsDir.appendingPathComponent("empty.txt")
        try FileManager.default.createDirectory(at: fixture.protocolsDir, withIntermediateDirectories: true)
        try Data().write(to: transcript)
        job.transcriptPath = transcript
        job.state = .generatingProtocol
        queue.insertJobForTesting(job)
        try fixture.retention.registry.register(
            jobID: job.id, paths: fixture.relocatedTracks(of: job), root: fixture.output, recordedAt: job.artifactStartTime,
        )

        queue.markOutputWritten(jobID: job.id, output: transcript)

        let entry = try XCTUnwrap(fixture.retention.registry.entries.first)
        XCTAssertNil(entry.eligibleAt)
    }

    /// The fixture.output has to still exist when the audio is deleted: a transcript
    /// the user removed since leaves the audio as the only copy.
    func testAnOutputDeletedAfterTheJobFinishedKeepsTheAudio() async throws {
        fixture.enabled = false
        let queue = fixture.makeQueue(protocolGen: nil)
        try queue.enqueue(fixture.makeRecordedJob())
        await queue.processNext()
        let finished = try XCTUnwrap(queue.jobs.first)
        try FileManager.default.removeItem(at: XCTUnwrap(finished.transcriptPath))

        fixture.enabled = true
        await queue.sweepRetainedRecordings()

        XCTAssertTrue(try fixture.relocatedTracks(of: finished).allSatisfy(fixture.exists))
    }
}
