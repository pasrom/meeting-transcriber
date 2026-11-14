@testable import MeetingTranscriber
import XCTest

/// Coverage for the pure-I/O `PipelineSnapshot` helpers extracted from
/// `PipelineQueue`. The mutation/recovery logic (state-reset on load,
/// orphan filtering, naming-cache rebuild) stays in `PipelineQueue` and
/// is covered through the existing PipelineQueue end-to-end tests.
final class PipelineSnapshotTests: XCTestCase {
    // MARK: - load: missing file

    func testLoadReturnsNilWhenSnapshotMissing() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        XCTAssertNil(try PipelineSnapshot.load(from: dir))
    }

    // MARK: - save → load round-trip

    func testSaveAndLoadRoundTripPreservesAllFields() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        let mixURL = dir.appendingPathComponent("rec_mix.wav")
        var job = PipelineJob(
            meetingTitle: "Sync",
            appName: "Zoom",
            mixPath: mixURL,
            appPath: nil,
            micPath: nil,
            micDelay: 0.123,
            participants: ["A", "B"],
        )
        job.state = .diarizing
        job.warnings = ["one warning"]

        try PipelineSnapshot.save([job], to: dir)

        let loaded = try XCTUnwrap(try PipelineSnapshot.load(from: dir))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, job.id)
        XCTAssertEqual(loaded[0].meetingTitle, "Sync")
        XCTAssertEqual(loaded[0].appName, "Zoom")
        XCTAssertEqual(loaded[0].mixPath, mixURL)
        XCTAssertEqual(loaded[0].state, .diarizing)
        XCTAssertEqual(loaded[0].participants, ["A", "B"])
        XCTAssertEqual(loaded[0].warnings, ["one warning"])
    }

    // MARK: - save: produces the expected filename

    func testSaveWritesToSnapshotFilename() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        try PipelineSnapshot.save([], to: dir)
        let snapshotPath = dir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: snapshotPath.path),
            "Expected snapshot at \(snapshotPath.path)",
        )
    }

    // MARK: - save: atomic replace cleans up the staging file

    func testSaveCleansUpStagingFile() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        try PipelineSnapshot.save([], to: dir)
        let stagingPath = dir.appendingPathComponent(PipelineSnapshot.stagingFilename)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stagingPath.path),
            "replaceItemAt should consume the staging file",
        )
    }

    // MARK: - load: corrupt JSON

    func testLoadThrowsOnCorruptJSON() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        let snapshotPath = dir.appendingPathComponent(PipelineSnapshot.snapshotFilename)
        try Data("not valid json".utf8).write(to: snapshotPath)
        XCTAssertThrowsError(try PipelineSnapshot.load(from: dir)) { error in
            XCTAssertTrue(error is DecodingError, "Expected DecodingError, got \(error)")
        }
    }

    // MARK: - save: empty array

    func testSaveEmptyArrayLoadsBackAsEmpty() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        try PipelineSnapshot.save([], to: dir)
        let loaded = try XCTUnwrap(try PipelineSnapshot.load(from: dir))
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Meeting-notes template

    func testTheTemplateSurvivesARoundTrip() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        let job = PipelineJob(
            meetingTitle: "Board", appName: "Teams", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
            protocolTemplate: .file(name: "Board"),
        )

        try PipelineSnapshot.save([job], to: dir)

        let loaded = try XCTUnwrap(try PipelineSnapshot.load(from: dir)?.first)
        XCTAssertEqual(loaded.protocolTemplate, .file(name: "Board"))
    }

    /// A snapshot an older build wrote has no template key; it must still decode.
    func testASnapshotWithoutTheTemplateKeyDecodes() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","meetingTitle":"Sync","appName":"Zoom","micDelay":0,
          "participants":[],"enqueuedAt":0,"state":"waiting","warnings":[]}]
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let loaded = try XCTUnwrap(try PipelineSnapshot.load(from: dir)?.first)

        XCTAssertEqual(loaded.meetingTitle, "Sync")
        XCTAssertNil(loaded.protocolTemplate)
    }
}
