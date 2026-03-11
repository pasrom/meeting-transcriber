import XCTest

@testable import MeetingTranscriber

@MainActor
final class DualSourceRecorderTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let recorder = DualSourceRecorder()
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - PID File Path

    func testPidFilePath() {
        let path = DualSourceRecorder.pidFilePath
        XCTAssertTrue(path.path.contains(".meeting-transcriber"))
        XCTAssertEqual(path.lastPathComponent, "audiotap.pid")
    }

    // MARK: - Kill Orphaned Audiotap

    func testKillOrphanedNoPidFileIsNoOp() {
        // Should not crash when no PID file exists
        DualSourceRecorder.killOrphanedAudiotap()
    }

    // MARK: - Cleanup Temp Files

    func testCleanupRemovesTmpButNotWav() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let tmpFile = tmpDir.appendingPathComponent("20260311_100000_app_raw.tmp")
        let wavFile = tmpDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data("tmp".utf8).write(to: tmpFile)
        try Data("wav".utf8).write(to: wavFile)

        DualSourceRecorder.cleanupTempFiles(recordingsDir: tmpDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpFile.path), "tmp file should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavFile.path), "wav file should be kept")
    }

    func testCleanupNonexistentDirIsNoOp() {
        let nowhere = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)")
        DualSourceRecorder.cleanupTempFiles(recordingsDir: nowhere)
        // Should not crash
    }

    // MARK: - Audiotap Discovery

    func testFindAudiotapReturnsNilWhenMissing() {
        // In test environment without a bundle, at least doesn't crash
        // May return nil or a valid path depending on the dev environment
        _ = DualSourceRecorder.findAudiotap()
    }

    // MARK: - Recordings Directory

    func testRecordingsDirPath() {
        let dir = DualSourceRecorder.recordingsDir
        XCTAssertTrue(dir.path.contains("Library/Application Support/MeetingTranscriber/recordings"))
    }

    // MARK: - Stop Without Start

    func testStopWithoutStartThrows() {
        let recorder = DualSourceRecorder()
        XCTAssertThrowsError(try recorder.stop()) { error in
            XCTAssertTrue(error is RecorderError)
        }
    }

    // MARK: - RecordingResult

    func testRecordingResultFields() {
        let result = RecordingResult(
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: URL(fileURLWithPath: "/tmp/app.wav"),
            micPath: URL(fileURLWithPath: "/tmp/mic.wav"),
            micDelay: 0.15,
            muteTimeline: [MuteTransition(timestamp: 10.0, isMuted: true)],
            recordingStart: 1000.0
        )

        XCTAssertEqual(result.mixPath.lastPathComponent, "mix.wav")
        XCTAssertEqual(result.appPath?.lastPathComponent, "app.wav")
        XCTAssertEqual(result.micPath?.lastPathComponent, "mic.wav")
        XCTAssertEqual(result.micDelay, 0.15)
        XCTAssertEqual(result.muteTimeline.count, 1)
        XCTAssertTrue(result.muteTimeline[0].isMuted)
        XCTAssertEqual(result.recordingStart, 1000.0)
    }

    func testRecordingResultNoTracks() {
        let result = RecordingResult(
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            muteTimeline: [],
            recordingStart: 0
        )

        XCTAssertNil(result.appPath)
        XCTAssertNil(result.micPath)
        XCTAssertTrue(result.muteTimeline.isEmpty)
    }
}
