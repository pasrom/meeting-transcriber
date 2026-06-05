import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Crash-recovery coverage for `DualSourceRecorder` (#379 durability, part 3).
/// Split from `DualSourceRecorderTests` to keep that class under the
/// type-body-length lint cap.
@MainActor
final class DualSourceRecorderCrashRecoveryTests: XCTestCase {
    /// Only a `_app_raw.tmp` with no matching `_mix.wav` is a crash orphan:
    /// one that already has a mix was processed, and a lone `_mic.wav` (no
    /// raw app temp) isn't an app-track orphan.
    func testCrashedRecordingStemsDetectsTmpWithoutMix() {
        let stems = DualSourceRecorder.crashedRecordingStems(in: [
            "20260311_100000_app16k_raw.tmp", // crashed: temp, no mix
            "20260311_100000_mic.wav",
            "20260311_110000_app_raw.tmp", // already processed: temp + mix
            "20260311_110000_mix.wav",
            "20260311_120000_mic.wav", // mic only, no temp → not an app orphan
            "notes.txt",
        ])
        XCTAssertEqual(stems, ["20260311_100000"])
    }

    /// A crashed recording (surviving raw app `.tmp` + mic WAV, no mix) is
    /// re-mixed into a readable `_mix.wav` and the raw temp is consumed.
    func testRecoverCrashedRecordingsRemixesOrphanedRawAppAndMic() throws {
        let dir = try makeTempDirectory(prefix: "crash_recover")
        let stem = "20260311_140000"
        let appTmp = dir.appendingPathComponent(stem + "_app16k_raw.tmp")
        // 2 s of 16 kHz mono float — the surviving app track (AppAudioCapture
        // resamples to 16 kHz mono in the IOProc, so the temp is already there).
        try writeRawFloat32([Float](repeating: 0.3, count: 16000 * 2), to: appTmp)
        let micWav = dir.appendingPathComponent(stem + "_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        // A crashed recording's temp predates the relaunch — backdate it past
        // the in-progress guard.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: appTmp.path,
        )

        let count = DualSourceRecorder.recoverCrashedRecordings(in: dir)

        XCTAssertEqual(count, 1, "the crashed recording should be recovered")
        let mix = dir.appendingPathComponent(stem + "_mix.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mix.path), "a mix should be produced")
        XCTAssertGreaterThan(
            try AudioMixer.loadAudioFileAsFloat32(url: mix).count, 0,
            "the recovered mix should contain audio",
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: appTmp.path), "the raw temp should be consumed")
    }

    /// A pre-upgrade temp (`_app_raw.tmp`, raw device-rate stereo) must also be
    /// detected as a crash orphan — upgrading the app must not strand audio
    /// recorded by the previous version.
    func testCrashedRecordingStemsDetectsLegacyTempFormat() {
        let stems = DualSourceRecorder.crashedRecordingStems(in: [
            "20260311_100000_app16k_raw.tmp", // current format, no mix
            "20260311_110000_app_raw.tmp", // legacy format, no mix
            "20260311_120000_app_raw.tmp", // legacy, already processed
            "20260311_120000_mix.wav",
        ])
        XCTAssertEqual(stems.sorted(), ["20260311_100000", "20260311_110000"])
    }

    /// A legacy temp contains RAW DEVICE-RATE audio (typically 48 kHz stereo),
    /// not the 16 kHz mono the current capture writes. Recovery must read it
    /// with the legacy interpretation — reading 48 kHz stereo as 16 kHz mono
    /// yields ~6× slowed channel-interleaved garbage (and an empty transcript).
    func testRecoverLegacyTempUsesDeviceCaptureFormat() throws {
        let dir = try makeTempDirectory(prefix: "crash_legacy")
        let stem = "20260311_160000"
        let appTmp = dir.appendingPathComponent(stem + "_app_raw.tmp")
        // 1 s of 48 kHz interleaved stereo — what a pre-upgrade version wrote.
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)
        let micWav = dir.appendingPathComponent(stem + "_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: appTmp.path,
        )

        let count = DualSourceRecorder.recoverCrashedRecordings(in: dir)

        XCTAssertEqual(count, 1)
        let appWav = dir.appendingPathComponent(stem + "_app.wav")
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: appWav)
        XCTAssertEqual(
            samples.count, 16000, accuracy: 800,
            "1 s of legacy 48 kHz stereo must recover to 1 s at 16 kHz, not 6 s of garbage",
        )
    }

    /// A freshly-written `.tmp` (recent mtime) looks like an in-progress
    /// recording, not a crash — recovery must leave it untouched.
    func testRecoverCrashedRecordingsSkipsInProgressTemp() throws {
        let dir = try makeTempDirectory(prefix: "crash_inprogress")
        let stem = "20260311_150000"
        let appTmp = dir.appendingPathComponent(stem + "_app16k_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 48000 * 2), to: appTmp)

        let count = DualSourceRecorder.recoverCrashedRecordings(in: dir)

        XCTAssertEqual(count, 0, "an in-progress (fresh) temp must not be recovered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appTmp.path), "the temp must be left untouched")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(stem + "_mix.wav").path),
            "no mix should be produced for an in-progress temp",
        )
    }
}
