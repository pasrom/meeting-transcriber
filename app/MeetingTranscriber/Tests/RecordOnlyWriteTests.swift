@testable import MeetingTranscriber
import XCTest

/// A record-only write can be cut off part-way: on a quit it gets what is
/// left of the recording budget, and into an output folder on another volume
/// each file is a copy that takes seconds. Whatever point it stops at, the
/// output folder must not hold a truncated file under a final name, and the
/// recording must still be in the staging folder, where the next launch finds
/// it. The sidecar is what says a record-only recording is complete.
@MainActor
final class RecordOnlyWriteTests: XCTestCase {
    private struct Fixture {
        let staging: URL
        let output: URL
        let recording: RecordingResult
    }

    private func makeFixture() throws -> Fixture {
        let staging = try makeTempDirectory(prefix: "record_only_staging")
        let output = try makeTempDirectory(prefix: "record_only_output")
        let stem = "20260311_140000"
        var urls: [URL] = []
        for suffix in [RecordingFileSuffix.mix, RecordingFileSuffix.app, RecordingFileSuffix.mic] {
            let url = staging.appendingPathComponent(stem + suffix)
            try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: 16000), sampleRate: 16000, url: url)
            urls.append(url)
        }
        let recording = RecordingResult(
            mixPath: urls[0], appPath: urls[1], micPath: urls[2], micDelay: 0, recordingStartDate: Date(),
        )
        return Fixture(staging: staging, output: output, recording: recording)
    }

    private func makeWrite(_ fixture: Fixture, transfer: @escaping RecordOnlyWrite.Transfer) -> RecordOnlyWrite {
        RecordOnlyWrite(
            title: "Standup", appName: "Teams", recording: fixture.recording, trigger: .manual,
            participants: [], stoppedAt: Date(), destination: .unscoped(fixture.output), transfer: transfer,
        )
    }

    private func partials(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".partial") }
    }

    private func sourcesLeft(_ fixture: Fixture) -> [URL] {
        [fixture.recording.mixPath, fixture.recording.appPath, fixture.recording.micPath]
            .compactMap(\.self)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func finalNames(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".wav") || $0.hasSuffix(RecordingSidecar.filenameSuffix) }
            .filter { !$0.contains(".partial") }
            .sorted()
    }

    /// The copy of the app track stops half-way, as a copy the exit cuts off
    /// does.
    func testAWriteCutOffPartWayLeavesNoFileUnderAFinalNameAndTheRecordingInStaging() throws {
        let fixture = try makeFixture()
        let appTrack = try XCTUnwrap(fixture.recording.appPath)
        let write = makeWrite(fixture) { source, target in
            guard source == appTrack else { return try FileManager.default.copyItem(at: source, to: target) }
            let data = try Data(contentsOf: source)
            try data.prefix(data.count / 2).write(to: target)
            throw CocoaError(.fileWriteOutOfSpace)
        }

        XCTAssertThrowsError(try write.perform())

        XCTAssertEqual(try finalNames(in: fixture.output), [], "the output folder holds a partial or uncommitted file")
        XCTAssertEqual(try partials(in: fixture.output), [], "the write left its temporary copies behind")
        for source in [fixture.recording.mixPath, appTrack] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: source.path),
                "\(source.lastPathComponent) left staging before the write was complete",
            )
        }
    }

    func testACompleteWritePutsEveryFileAndTheSidecarInPlaceAndEmptiesStaging() throws {
        let fixture = try makeFixture()
        let write = makeWrite(fixture) { try FileManager.default.copyItem(at: $0, to: $1) }

        try write.perform()

        XCTAssertEqual(try finalNames(in: fixture.output), [
            "20260311_140000_app.wav", "20260311_140000_meta.json", "20260311_140000_mic.wav", "20260311_140000_mix.wav",
        ])
        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path)
        XCTAssertEqual(left, [], "the sources stayed in staging after the write was complete")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).filter { $0.contains(".partial") }
        XCTAssertEqual(leftovers, [])
    }

    /// The production transfer: a hard link here, since the test folders share
    /// a volume. The output must not depend on the staging file it was linked
    /// from, which the write removes at the end.
    func testTheDefaultTransferLeavesCompleteFilesOnceTheSourcesAreGone() throws {
        let fixture = try makeFixture()
        let expected = try Data(contentsOf: fixture.recording.mixPath)

        try makeWrite(fixture, transfer: RecordOnlyWrite.linkOrCopy).perform()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recording.mixPath.path))
        let placed = fixture.output.appendingPathComponent(fixture.recording.mixPath.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: placed), expected)
    }

    /// The sidecar is where a record-only write commits. A step after the
    /// sidecar is in place that fails (the owner-only permission change, on a
    /// file system that refuses it) must not undo that: reporting a failure
    /// and keeping the staging sources made the next launch process the same
    /// recording a second time, next to its finished record-only output.
    func testAFailureAfterTheSidecarIsInPlaceStillCommitsTheWrite() throws {
        let fixture = try makeFixture()
        var write = makeWrite(fixture) { try FileManager.default.copyItem(at: $0, to: $1) }
        write.writeSidecar = { sidecar, url in
            try sidecar.write(to: url)
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertNoThrow(try write.perform())

        XCTAssertTrue(try finalNames(in: fixture.output).contains("20260311_140000_meta.json"))
        XCTAssertEqual(sourcesLeft(fixture), [], "a committed write kept its sources, so they are processed again")
    }

    /// Before the sidecar is in place nothing is committed, so every source
    /// stays in staging for the next launch.
    func testASidecarThatIsNeverWrittenKeepsEverySourceInStaging() throws {
        let fixture = try makeFixture()
        var write = makeWrite(fixture) { try FileManager.default.copyItem(at: $0, to: $1) }
        write.writeSidecar = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }

        XCTAssertThrowsError(try write.perform())

        XCTAssertEqual(sourcesLeft(fixture).count, 3, "a source left staging before the write had committed")
        XCTAssertFalse(try finalNames(in: fixture.output).contains("20260311_140000_meta.json"))
    }

    /// An earlier recording with the same stem (two recordings in one second,
    /// or a clock set back) in the output folder.
    private func plantEarlierRecording(in output: URL) throws -> [URL: Data] {
        var files: [URL: Data] = [:]
        for (name, content) in [
            ("20260311_140000_meta.json", #"{"title":"An Earlier Recording"}"#),
            ("20260311_140000_mix.wav", "earlier mix"),
            ("20260311_140000_mic.wav", "earlier mic"),
        ] {
            let url = output.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
            files[url] = Data(content.utf8)
        }
        return files
    }

    private func assertUntouched(_ files: [URL: Data], file: StaticString = #filePath, line: UInt = #line) {
        for (url, content) in files {
            XCTAssertEqual(
                try? Data(contentsOf: url), content,
                "the earlier recording's \(url.lastPathComponent) was removed or overwritten", file: file, line: line,
            )
        }
    }

    /// A write that fails before its commit leaves an earlier recording of the
    /// same stem exactly as it was, and keeps its own sources in staging:
    /// neither recording may end up incoherent.
    func testAFailedWriteLeavesAnEarlierRecordingOfTheSameStemIntact() throws {
        let fixture = try makeFixture()
        let earlier = try plantEarlierRecording(in: fixture.output)
        var write = makeWrite(fixture) { try FileManager.default.copyItem(at: $0, to: $1) }
        write.writeSidecar = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }

        XCTAssertThrowsError(try write.perform())

        XCTAssertEqual(sourcesLeft(fixture).count, 3, "an earlier recording's sidecar was taken for this write's commit")
        assertUntouched(earlier)
    }

    /// A write that succeeds next to an earlier recording of the same stem
    /// takes a stem of its own and describes its own files.
    func testAWriteNextToAnEarlierRecordingOfTheSameStemTakesAStemOfItsOwn() throws {
        let fixture = try makeFixture()
        let earlier = try plantEarlierRecording(in: fixture.output)

        try makeWrite(fixture) { try FileManager.default.copyItem(at: $0, to: $1) }.perform()

        assertUntouched(earlier)
        let sidecar = try XCTUnwrap(RecordingSidecar.read(fromDirectory: fixture.output, basename: "20260311_140000-2"))
        XCTAssertEqual(sidecar.files.mix, "20260311_140000-2_mix.wav")
        XCTAssertEqual(sidecar.files.app, "20260311_140000-2_app.wav")
        XCTAssertEqual(sidecar.files.mic, "20260311_140000-2_mic.wav")
        for name in [sidecar.files.mix, sidecar.files.app, sidecar.files.mic].compactMap(\.self) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent(name).path))
        }
        XCTAssertEqual(sourcesLeft(fixture), [])
    }

    /// A write the exit cut off cannot clean up after itself; its temporary
    /// copy (up to the size of the recording, in a folder a sync tool
    /// replicates) is removed once it is clearly stale. Only names this code
    /// produces are its own: the folder is the user's, and other tools leave
    /// hidden `.partial` files there too.
    func testTheSweepRemovesOnlyTemporaryCopiesThisCodeNames() throws {
        let dir = try makeTempDirectory(prefix: "record_only_sweep")
        let ours = [
            ".20260310_090000_mix.wav.partial", ".20260310_090000_app.wav.partial",
            ".20260310_090000_meta.json.partial", ".20260310_090000-2_mic.wav.partial",
        ]
        let theirs = [".upload.partial", ".notes.partial", ".20260310_090000_mix.partial", "20260310_090000_mix.wav.partial"]
        for name in ours + theirs {
            try Data(repeating: 0x52, count: 16).write(to: dir.appendingPathComponent(name))
        }

        RecordOnlyWrite.removeStaleTemporaryCopies(in: dir, changedBefore: Date().addingTimeInterval(3600))

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, theirs.sorted(), "the sweep removed a file this code did not create, or left one it did")
    }

    /// A temporary copy carries its source's modification time (a hard link
    /// is the source, and a copy takes its dates), so an old modification
    /// time does not make a copy that is still being written stale. Its age is
    /// when it was created here.
    func testATemporaryCopyWithAnOldSourceTimeIsNotStale() throws {
        let dir = try makeTempDirectory(prefix: "record_only_sweep_age")
        let copy = dir.appendingPathComponent(".20260310_090000_mix.wav.partial")
        try Data(repeating: 0x52, count: 16).write(to: copy)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: copy.path,
        )

        RecordOnlyWrite.removeStaleTemporaryCopies(
            in: dir, changedBefore: Date().addingTimeInterval(-RecordOnlyWrite.staleTemporaryCopyAge),
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "a fresh copy of an old source was swept")
    }

    /// A source that cannot be removed after the write committed is reported:
    /// left in staging, the mix is picked up by the orphan scan and processed
    /// again.
    func testASourceThatCannotBeRemovedIsReported() throws {
        let fixture = try makeFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.staging.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.staging.path)
        }

        let left = try makeWrite(fixture) { try FileManager.default.copyItem(at: $0, to: $1) }.perform()

        XCTAssertEqual(left.count, 3, "a source left in staging was not reported")
        XCTAssertTrue(try finalNames(in: fixture.output).contains("20260311_140000_meta.json"))
    }
}
