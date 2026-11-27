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

    // MARK: - transcription target

    func testTranscriptionTargetSurvivesSaveAndLoad() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        var job = PipelineJob(
            meetingTitle: "Target", appName: "Zoom",
            mixPath: dir.appendingPathComponent("rec_mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.transcriptionTarget = .local

        try PipelineSnapshot.save([job], to: dir)

        let loaded = try XCTUnwrap(try PipelineSnapshot.load(from: dir))
        XCTAssertEqual(loaded.first?.transcriptionTarget, .local)
    }

    func testSnapshotWithoutTranscriptionTargetStillLoads() throws {
        let dir = try makeTempDirectory(prefix: "pipeline-snapshot")
        var job = PipelineJob(
            meetingTitle: "Before Targets", appName: "Zoom",
            mixPath: dir.appendingPathComponent("rec_mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.transcriptionTarget = .local
        let encoded = try JSONEncoder().encode([job])
        var jobs = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertNotNil(jobs[0].removeValue(forKey: "transcriptionTarget"), "precondition: the key is encoded")
        try JSONSerialization.data(withJSONObject: jobs)
            .write(to: dir.appendingPathComponent(PipelineSnapshot.snapshotFilename))

        let loaded = try XCTUnwrap(try PipelineSnapshot.load(from: dir))
        XCTAssertEqual(loaded.first?.id, job.id)
        XCTAssertNil(loaded.first?.transcriptionTarget)
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
}
