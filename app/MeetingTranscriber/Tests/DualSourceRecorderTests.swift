import AudioTapLib
@testable import MeetingTranscriber
import XCTest

@MainActor
final class DualSourceRecorderTests: XCTestCase {
    // MARK: - Initial State

    func testInitialState() {
        let recorder = DualSourceRecorder()
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - Level Forwarding

    func testLevelsDefaultToSilenceWithoutSession() {
        let recorder = DualSourceRecorder()
        XCTAssertEqual(recorder.appLevelDBFS, -120, accuracy: 0.001)
        XCTAssertEqual(recorder.micLevelDBFS, -120, accuracy: 0.001)
    }

    // MARK: - Cleanup Temp Files

    func testCleanupRemovesTmpButNotWav() throws {
        let tmpDir = try makeTempDirectory(prefix: "cleanup_test")

        let tmpFile = tmpDir.appendingPathComponent("20260311_100000_app_raw.tmp")
        let wavFile = tmpDir.appendingPathComponent("20260311_100000_mix.wav")
        try Data("tmp".utf8).write(to: tmpFile)
        try Data("wav".utf8).write(to: wavFile)
        // A leftover crash temp is older than the in-progress guard.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: tmpFile.path,
        )

        DualSourceRecorder.cleanupTempFiles(recordingsDir: tmpDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpFile.path), "tmp file should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavFile.path), "wav file should be kept")
    }

    func testCleanupKeepsInProgressTmp() throws {
        let tmpDir = try makeTempDirectory(prefix: "cleanup_inprogress")
        // A freshly-written temp (recent mtime) is an in-progress recording,
        // not a crash leftover — cleanup must leave it for the live recorder.
        let tmpFile = tmpDir.appendingPathComponent("20260311_100000_app_raw.tmp")
        try Data("tmp".utf8).write(to: tmpFile)

        DualSourceRecorder.cleanupTempFiles(recordingsDir: tmpDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpFile.path), "a fresh in-progress temp must be kept")
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

    func testDownmix4ChannelsToMono() {
        let samples: [Float] = [0.4, 0.8, 0.0, 0.0, 0.2, 0.6, 0.0, 0.0]
        let result = DualSourceRecorder.downmixToMono(samples, channels: 4)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 0.3, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.2, accuracy: 0.001)
    }

    // MARK: - RecorderError Descriptions

    func testRecorderErrorNotRecordingDescription() {
        XCTAssertEqual(RecorderError.notRecording.errorDescription, "Not currently recording")
    }

    func testRecorderErrorNoAudioDataDescription() {
        XCTAssertEqual(RecorderError.noAudioData.errorDescription, "No audio data recorded")
    }

    func testRecorderErrorUnsupportedOSDescription() {
        XCTAssertEqual(RecorderError.unsupportedOS.errorDescription, "macOS 14.2+ required for audio capture")
    }

    // MARK: - Cleanup Edge Cases

    func testCleanupMultipleTmpFiles() throws {
        let tmpDir = try makeTempDirectory(prefix: "cleanup_multi")

        let tmp1 = tmpDir.appendingPathComponent("20260311_100000_app_raw.tmp")
        let tmp2 = tmpDir.appendingPathComponent("20260311_110000_app_raw.tmp")
        let wav1 = tmpDir.appendingPathComponent("20260311_100000_mix.wav")
        for file in [tmp1, tmp2, wav1] {
            try Data("x".utf8).write(to: file)
        }
        // Both temps are stale crash leftovers (older than the in-progress guard).
        for tmp in [tmp1, tmp2] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: tmp.path,
            )
        }

        DualSourceRecorder.cleanupTempFiles(recordingsDir: tmpDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav1.path))
    }

    func testRecorderErrorPermissionDeniedDescription() {
        let error = RecorderError.permissionDenied("Microphone broken")
        XCTAssertEqual(error.errorDescription, "Permission problem: Microphone broken")
    }

    func testCleanupEmptyDirectory() throws {
        let tmpDir = try makeTempDirectory(prefix: "cleanup_empty")
        DualSourceRecorder.cleanupTempFiles(recordingsDir: tmpDir)
    }

    // MARK: - Mix Fallback Without Mic (noMic / no mic hardware)

    /// Verifies that when no mic is present, the mix.wav uses resampled 16kHz samples
    /// instead of raw device-rate samples. Regression test for the bug where 48kHz samples
    /// were saved with a 16kHz header, producing a file 3× too long.
    func testMixFallbackWithoutMicUsesResampledSamples() throws {
        let tmpDir = try makeTempDirectory(prefix: "mix_fallback")

        // Simulate 1 second of 48kHz mono app audio (captured by CATapDescription)
        let deviceRate = 48000
        let targetRate = 16000
        let appSamples = [Float](repeating: 0.5, count: deviceRate) // 1s at 48kHz

        // Resample to 16kHz (what the fix does)
        let appSamples16k = AudioMixer.resample(appSamples, from: deviceRate, to: targetRate)
        XCTAssertEqual(
            appSamples16k.count,
            targetRate,
            accuracy: 2200,
            "Resampled should have ~16000 samples for 1s",
        )

        // Save mix using resampled samples (the FIXED path)
        let mixPath = tmpDir.appendingPathComponent("mix.wav")
        try AudioMixer.saveWAV(samples: appSamples16k, sampleRate: targetRate, url: mixPath)

        // Also save what the BUGGY path would have produced
        let buggyMixPath = tmpDir.appendingPathComponent("buggy_mix.wav")
        try AudioMixer.saveWAV(samples: appSamples, sampleRate: targetRate, url: buggyMixPath)

        let mixSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: mixPath.path)[.size] as? Int)
        let buggySize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: buggyMixPath.path)[.size] as? Int)

        // Fixed mix: ~1s of 16kHz Int16 = ~32044 bytes
        // Buggy mix: ~3s of "16kHz" Int16 = ~96044 bytes (3× too long)
        XCTAssertEqual(
            Double(mixSize) / Double(buggySize),
            1.0 / 3.0,
            accuracy: 0.05,
            "Buggy mix should be 3× larger than fixed mix",
        )

        // Verify fixed mix has correct duration
        let expectedSamples = targetRate // 1s at 16kHz
        let actualSamples = (mixSize - 44) / 2 // Int16 = 2 bytes per sample
        XCTAssertEqual(
            actualSamples,
            expectedSamples,
            accuracy: 2200,
            "Fixed mix should have ~16000 samples (1s at 16kHz)",
        )
    }

    // MARK: - crossCheckAppRate

    func testCrossCheckCorrectRateUnchanged() {
        // 60s of 48kHz stereo float32 = 23,040,000 bytes
        let result = DualSourceRecorder.crossCheckAppRate(
            deviceRate: 48000,
            appRawBytes: 23_040_000,
            appChannels: 2,
            micDurationSeconds: 60.0,
            micDelay: 0,
        )
        XCTAssertEqual(result, 48000)
    }

    func testCrossCheckDetectsMismatch() {
        // 60s of 48kHz stereo float32 = 23,040,000 bytes
        // Device wrongly reports 24000 → cross-check computes ~48000 → overrides
        let result = DualSourceRecorder.crossCheckAppRate(
            deviceRate: 24000,
            appRawBytes: 23_040_000,
            appChannels: 2,
            micDurationSeconds: 60.0,
            micDelay: 0,
        )
        XCTAssertEqual(result, 48000)
    }

    func testCrossCheckWithMicDelay() {
        // mic started 0.5s after app → app recorded 60.5s
        // 60.5s of 48kHz stereo float32 = 60.5 * 48000 * 2 * 4 = 23,232,000
        let result = DualSourceRecorder.crossCheckAppRate(
            deviceRate: 24000,
            appRawBytes: 23_232_000,
            appChannels: 2,
            micDurationSeconds: 60.0,
            micDelay: 0.5,
        )
        XCTAssertEqual(result, 48000)
    }

    func testCrossCheckNoMicReturnsDeviceRate() {
        let result = DualSourceRecorder.crossCheckAppRate(
            deviceRate: 24000,
            appRawBytes: 23_040_000,
            appChannels: 2,
            micDurationSeconds: nil,
            micDelay: 0,
        )
        XCTAssertEqual(result, 24000)
    }

    func testCrossCheckShortRecordingReturnsDeviceRate() {
        let result = DualSourceRecorder.crossCheckAppRate(
            deviceRate: 24000,
            appRawBytes: 48000 * 2 * 4 * 2,
            appChannels: 2,
            micDurationSeconds: 2.0,
            micDelay: 0,
        )
        XCTAssertEqual(result, 24000)
    }

    // MARK: - buildRecording

    /// Neither channel produced audio (0-byte app temp, no mic) → noAudioData.
    func testBuildRecordingThrowsWhenNoAudioCaptured() throws {
        let dir = try makeTempDirectory(prefix: "build_none")
        let emptyApp = dir.appendingPathComponent("20260311_100000_app_raw.tmp")
        try Data().write(to: emptyApp)

        let result = AudioCaptureResult(
            appAudioFileURL: emptyApp,
            micAudioFileURL: nil,
            actualSampleRate: 48000,
            actualChannels: 2,
            micDelay: 0,
        )

        XCTAssertThrowsError(
            try DualSourceRecorder.buildRecording(
                from: result,
                recordingsDir: dir,
                timestamp: "20260311_100000",
                recordingStart: 1000,
                format: CaptureFormat(requestedChannels: 2, requestedRate: 48000, targetRate: 16000),
            ),
        ) { error in
            guard case RecorderError.noAudioData = error else {
                return XCTFail("expected noAudioData, got \(error)")
            }
        }
    }

    /// App audio only (no mic) → app track saved, mix falls back to the
    /// resampled app samples, and the raw `.tmp` is consumed.
    func testBuildRecordingAppOnlyProducesMixFromResampledApp() throws {
        let dir = try makeTempDirectory(prefix: "build_app")
        let appTmp = dir.appendingPathComponent("20260311_120000_app_raw.tmp")
        // 1 s of 48 kHz interleaved stereo.
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: nil,
                actualSampleRate: 48000, actualChannels: 2, micDelay: 0,
            ),
            recordingsDir: dir, timestamp: "20260311_120000", recordingStart: 1000,
            format: CaptureFormat(requestedChannels: 2, requestedRate: 48000, targetRate: 16000),
        )

        XCTAssertNotNil(result.appPath, "app track should be saved")
        XCTAssertNil(result.micPath, "no mic track")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mixPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appTmp.path), "raw .tmp should be consumed")
    }

    /// Mic audio only (0-byte app temp) → mic track surfaces, mix falls back to
    /// the mic samples.
    func testBuildRecordingMicOnlyProducesMixFromMic() throws {
        let dir = try makeTempDirectory(prefix: "build_mic")
        let appTmp = dir.appendingPathComponent("20260311_130000_app_raw.tmp")
        try Data().write(to: appTmp)
        let micWav = dir.appendingPathComponent("20260311_130000_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: 48000, actualChannels: 2, micDelay: 0,
            ),
            recordingsDir: dir, timestamp: "20260311_130000", recordingStart: 1000,
            format: CaptureFormat(requestedChannels: 2, requestedRate: 48000, targetRate: 16000),
        )

        XCTAssertNil(result.appPath, "no app track")
        XCTAssertEqual(result.micPath, micWav)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mixPath.path))
    }

    /// Both channels present → both tracks surface and the mix is produced via
    /// AudioMixer (delay alignment + mixing).
    func testBuildRecordingAppAndMicProducesMixedTracks() throws {
        let dir = try makeTempDirectory(prefix: "build_both")
        let appTmp = dir.appendingPathComponent("20260311_140000_app_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)
        let micWav = dir.appendingPathComponent("20260311_140000_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: 48000, actualChannels: 2, micDelay: 0.1,
            ),
            recordingsDir: dir, timestamp: "20260311_140000", recordingStart: 1000,
            format: CaptureFormat(requestedChannels: 2, requestedRate: 48000, targetRate: 16000),
        )

        XCTAssertNotNil(result.appPath)
        XCTAssertEqual(result.micPath, micWav)
        XCTAssertEqual(result.micDelay, 0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mixPath.path))
    }

    /// Crash-recovery safety: the raw app `.tmp` is the only recoverable copy
    /// on the recovery path. If buildRecording fails *after* reading it but
    /// *before* a durable mix exists, it must leave the temp intact so the next
    /// recovery attempt can retry — eagerly deleting it would destroy the
    /// recording.
    func testBuildRecordingPreservesAppTempWhenLaterStepThrows() throws {
        let dir = try makeTempDirectory(prefix: "build_preserve")
        let appTmp = dir.appendingPathComponent("20260311_160000_app_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)
        // A mic file that exists and is larger than a WAV header but is not
        // decodable audio: buildRecording clears the size guard, then
        // AVAudioFile(forReading:) throws — failing the build after the temp
        // has been read but before any durable mix is written.
        let badMic = dir.appendingPathComponent("20260311_160000_mic.wav")
        try Data(repeating: 0xFF, count: 128).write(to: badMic)

        XCTAssertThrowsError(
            try DualSourceRecorder.buildRecording(
                from: AudioCaptureResult(
                    appAudioFileURL: appTmp, micAudioFileURL: badMic,
                    actualSampleRate: 48000, actualChannels: 2, micDelay: 0,
                ),
                recordingsDir: dir, timestamp: "20260311_160000", recordingStart: 1000,
                format: CaptureFormat(requestedChannels: 2, requestedRate: 48000, targetRate: 16000),
            ),
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appTmp.path),
            "app .tmp must survive a failed buildRecording so crash-recovery can retry",
        )
    }

    /// Captured channel count below the requested one (mono USB device) still
    /// produces a valid track — downmix is a passthrough for mono input.
    func testBuildRecordingToleratesChannelCountMismatch() throws {
        let dir = try makeTempDirectory(prefix: "build_chmismatch")
        let appTmp = dir.appendingPathComponent("20260311_150000_app_raw.tmp")
        // 1 s of 48 kHz MONO — but the recorder requested stereo.
        try writeRawFloat32([Float](repeating: 0.3, count: 48000), to: appTmp)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: nil,
                actualSampleRate: 48000, actualChannels: 1, micDelay: 0,
            ),
            recordingsDir: dir, timestamp: "20260311_150000", recordingStart: 1000,
            format: CaptureFormat(requestedChannels: 2, requestedRate: 48000, targetRate: 16000),
        )

        XCTAssertNotNil(result.appPath, "mono capture should still produce an app track")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mixPath.path))
    }

    /// Device-negotiated rate differing from the requested one (USB/Bluetooth
    /// renegotiation) still produces a valid track.
    func testBuildRecordingToleratesRateMismatch() throws {
        let dir = try makeTempDirectory(prefix: "build_ratemismatch")
        let appTmp = dir.appendingPathComponent("20260311_160000_app_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: nil,
                actualSampleRate: 48000, actualChannels: 2, micDelay: 0,
            ),
            // Requested 44.1 kHz but the device delivered 48 kHz.
            recordingsDir: dir, timestamp: "20260311_160000", recordingStart: 1000,
            format: CaptureFormat(requestedChannels: 2, requestedRate: 44100, targetRate: 16000),
        )

        XCTAssertNotNil(result.appPath, "rate mismatch should still produce an app track")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mixPath.path))
    }

    /// An app temp already at the target rate must be trusted — the
    /// mic-duration rate heuristic must not re-warp it. Scenario: the mic died
    /// mid-recording (restart retries exhausted), so the mic track is much
    /// shorter than the app track; inferring the app rate from that short
    /// reference would override 16 kHz with a bogus higher rate and time-warp
    /// a healthy track.
    func testBuildRecordingTrustsTargetRateAppTempOverMicDurationInference() throws {
        let dir = try makeTempDirectory(prefix: "build_trust16k")
        let appTmp = dir.appendingPathComponent("20260311_180000_app_raw.tmp")
        // 10 s of 16 kHz mono app audio, but only 4 s of mic.
        try writeRawFloat32([Float](repeating: 0.3, count: 16000 * 10), to: appTmp)
        let micWav = dir.appendingPathComponent("20260311_180000_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000 * 4), sampleRate: 16000, url: micWav)

        let result = try DualSourceRecorder.buildRecording(
            from: AudioCaptureResult(
                appAudioFileURL: appTmp, micAudioFileURL: micWav,
                actualSampleRate: 16000, actualChannels: 1, micDelay: 0,
            ),
            recordingsDir: dir, timestamp: "20260311_180000", recordingStart: 1000,
            format: CaptureFormat(requestedChannels: 1, requestedRate: 16000, targetRate: 16000),
        )

        let appPath = try XCTUnwrap(result.appPath)
        let out = try AudioMixer.loadAudioFileAsFloat32(url: appPath)
        XCTAssertEqual(
            out.count, 160_000, accuracy: 800,
            "a target-rate temp must keep its duration regardless of mic length",
        )
    }

    // Crash-recovery coverage (#379 durability, part 3) lives in
    // DualSourceRecorderCrashRecoveryTests.swift (type-body-length cap).
}
