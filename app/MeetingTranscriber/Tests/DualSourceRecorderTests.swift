@testable import MeetingTranscriber
import XCTest

@MainActor
final class DualSourceRecorderTests: XCTestCase {
    // MARK: - Initial State

    func testInitialState() {
        let recorder = DualSourceRecorder()
        XCTAssertFalse(recorder.isRecording)
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
            recordingStart: 1000.0,
        )

        XCTAssertEqual(result.mixPath.lastPathComponent, "mix.wav")
        XCTAssertEqual(result.appPath?.lastPathComponent, "app.wav")
        XCTAssertEqual(result.micPath?.lastPathComponent, "mic.wav")
        XCTAssertEqual(result.micDelay, 0.15)
        XCTAssertEqual(result.recordingStart, 1000.0)
    }

    func testRecordingResultNoTracks() {
        let result = RecordingResult(
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            recordingStart: 0,
        )

        XCTAssertNil(result.appPath)
        XCTAssertNil(result.micPath)
    }

    // MARK: - downmixToMono

    func testDownmixMonoPassthrough() {
        let mono: [Float] = [0.1, 0.2, 0.3, 0.4]
        let result = DualSourceRecorder.downmixToMono(mono, channels: 1)
        XCTAssertEqual(result, mono)
    }

    func testDownmixStereoToMono() {
        // Interleaved stereo: [L1, R1, L2, R2]
        let stereo: [Float] = [0.2, 0.8, 0.4, 0.6]
        let result = DualSourceRecorder.downmixToMono(stereo, channels: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 0.5, accuracy: 0.001) // (0.2+0.8)/2
        XCTAssertEqual(result[1], 0.5, accuracy: 0.001) // (0.4+0.6)/2
    }

    func testDownmixPreservesSampleCount() {
        // Mono: N samples in → N samples out (no halving)
        let samples = [Float](repeating: 0.5, count: 1000)
        let result = DualSourceRecorder.downmixToMono(samples, channels: 1)
        XCTAssertEqual(result.count, 1000, "Mono passthrough must not halve sample count")
    }

    func testDownmixStereoHalvesSampleCount() {
        let samples = [Float](repeating: 0.5, count: 1000)
        let result = DualSourceRecorder.downmixToMono(samples, channels: 2)
        XCTAssertEqual(result.count, 500)
    }

    func testDownmixEmptyArray() {
        let result = DualSourceRecorder.downmixToMono([], channels: 2)
        XCTAssertEqual(result, [])
    }

    func testDownmixIncompleteFrame() {
        // 5 samples with 2 channels → 4 used (2 frames), last sample dropped
        let samples: [Float] = [1.0, 0.0, 0.0, 1.0, 0.5]
        let result = DualSourceRecorder.downmixToMono(samples, channels: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.5, accuracy: 0.001)
    }
}
