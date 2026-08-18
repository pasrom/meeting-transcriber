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

    /// A microphone-only recording leaves no raw app temp, so nothing marked it
    /// as crashed and its audio was lost. An in-progress marker written at start
    /// and removed at stop is the signal, because it is the one thing only a
    /// crash leaves behind.
    func testCrashedRecordingStemsDetectsAMicOnlyRecordingByItsMarker() {
        let stems = DualSourceRecorder.crashedRecordingStems(in: [
            "20260311_100000_recording.marker", // crashed mic-only: marker, no mix
            "20260311_100000_mic.wav",
            "notes.txt",
        ])
        XCTAssertEqual(stems, ["20260311_100000"])
    }

    /// THE regression guard. "A mic track with no mix" is the normal end state
    /// of every successfully processed recording: `AudioPersistencePolicy` moves
    /// the mix into the output folder and leaves the mic track in staging.
    /// Treating that as a crash signature once re-processed 40 real recordings
    /// on a live archive. Only the marker may ever mean crash.
    func testAFinishedRecordingIsNeverMistakenForACrash() {
        let stems = DualSourceRecorder.crashedRecordingStems(in: [
            // Exactly what a processed mic-only recording leaves behind.
            "20260311_120000_mic.wav",
            // And a processed dual-source one, whose mix also moved away.
            "20260311_130000_mic.wav",
            "20260311_130000_app.wav",
        ])
        XCTAssertTrue(stems.isEmpty, "no marker means no crash, however incomplete the leftovers look")
    }

    /// A marker whose recording did finish (mix still alongside) is not a crash
    /// either: the mix is proof `stop()` ran, whatever happened to the marker.
    func testAMarkerNextToAMixIsNotACrash() {
        let stems = DualSourceRecorder.crashedRecordingStems(in: [
            "20260311_100000_recording.marker",
            "20260311_100000_mix.wav",
            "20260311_100000_mic.wav",
        ])
        XCTAssertTrue(stems.isEmpty)
    }

    /// The marker and the raw app temp describe the same crash, so a dual-source
    /// crash that leaves both must surface once, not twice.
    func testAStemIsReportedOnceWhenBothSignalsSurvive() {
        let stems = DualSourceRecorder.crashedRecordingStems(in: [
            "20260311_100000_recording.marker",
            "20260311_100000_app16k_raw.tmp",
            "20260311_100000_mic.wav",
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
        // A crash freezes EVERY track at the moment it happened, so backdate
        // both. Backdating only the temp described a state production never
        // produces (app track two minutes cold, mic track written just now, no
        // process alive) and hid the case the guard is really for: a mic
        // channel that gave up while the app track kept growing (issue #588) is
        // a live recording, and re-mixing under its writer would corrupt it.
        try backdate([appTmp, micWav])

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
        try backdate([appTmp, micWav])

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

    /// The point of the marker: a microphone-only recording that died leaves
    /// only its mic track, and before this it was lost because nothing said a
    /// crash had happened.
    func testACrashedMicrophoneOnlyRecordingIsRecoveredFromItsMarker() throws {
        let dir = try makeTempDirectory(prefix: "crash_mic_only")
        let stem = "20260311_170000"
        let micWav = dir.appendingPathComponent(stem + "_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        try backdate([micWav])

        let count = DualSourceRecorder.recoverCrashedRecordings(in: dir)

        XCTAssertEqual(count, 1, "a microphone-only crash must be recoverable")
        let mix = dir.appendingPathComponent(stem + "_mix.wav")
        XCTAssertGreaterThan(
            try AudioMixer.loadAudioFileAsFloat32(url: mix).count, 0,
            "the recovered mix must carry the microphone audio",
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "the marker is consumed, so a later run cannot recover the same recording twice",
        )
    }

    /// Once a stem has been dealt with, nothing may still look crashed. The
    /// recorder's own removal in `stop()` is not drivable here (it needs a live
    /// capture session), and deliberately does not have to be: `stop()` writes
    /// the mix before dropping the marker, and a stem with a mix is excluded
    /// from recovery whatever became of its marker.
    func testNothingLooksCrashedOnceRecoveryHasDealtWithIt() throws {
        let dir = try makeTempDirectory(prefix: "crash_marker_cleared")
        let stem = "20260311_180000"
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        let micWav = dir.appendingPathComponent(stem + "_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        try backdate([micWav])

        _ = DualSourceRecorder.recoverCrashedRecordings(in: dir)

        XCTAssertTrue(
            DualSourceRecorder.crashedRecordingStems(
                in: (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [],
            ).isEmpty,
            "nothing may still look crashed once it has been dealt with",
        )
    }

    /// The launch sequence in the order `PipelineController` actually runs it.
    /// Header repair rewrites the crashed mic track in place, which touches its
    /// mtime; if freshness then reads that as "a writer is still alive",
    /// recovery defers while `cleanupTempFiles` — which judges the temp by its
    /// own age — deletes the app track on the same launch. The remote half of
    /// the meeting would be gone before the next launch could rescue it.
    func testTheLaunchSequenceRecoversARecordingWhoseMicHeaderItJustRepaired() throws {
        let dir = try makeTempDirectory(prefix: "crash_launch_order")
        let stem = "20260311_190000"
        let appTmp = dir.appendingPathComponent(stem + "_app16k_raw.tmp")
        try writeRawFloat32([Float](repeating: 0.3, count: 16000 * 2), to: appTmp)
        let micWav = dir.appendingPathComponent(stem + "_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        try leaveHeaderUnfinalized(at: micWav) // what a killed writer leaves behind
        try backdate([appTmp, micWav])

        _ = WavHeaderRepair.repairUnfinalized(in: dir)
        let recovered = DualSourceRecorder.recoverCrashedRecordings(in: dir)
        DualSourceRecorder.cleanupTempFiles(recordingsDir: dir)

        XCTAssertEqual(recovered, 1, "repairing a header must not read as freshly captured audio")
        XCTAssertGreaterThan(
            try AudioMixer.loadAudioFileAsFloat32(url: dir.appendingPathComponent(stem + "_mix.wav")).count, 0,
            "the recovered mix must carry both tracks",
        )
    }

    /// Freshness spans every track, not just the app temp. A mic channel that
    /// gave up while the app track keeps growing (issue #588) is a live
    /// recording, and re-mixing under its writer would corrupt it.
    func testARecordingWhoseMicDiedButWhoseAppTrackGrowsIsNotRecovered() throws {
        let dir = try makeTempDirectory(prefix: "crash_mic_died")
        let stem = "20260311_240000"
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        try backdate([micWav]) // the dead channel, cold
        let appTmp = dir.appendingPathComponent(stem + RecordingFileSuffix.appRaw)
        try writeRawFloat32([Float](repeating: 0.3, count: 16000), to: appTmp) // still being written

        let count = DualSourceRecorder.recoverCrashedRecordings(in: dir)

        XCTAssertEqual(count, 0, "one live track is enough to mean the recording is still running")
    }

    /// Zero the `data` size the way a writer killed mid-stream does.
    private func leaveHeaderUnfinalized(at url: URL) throws {
        var data = try Data(contentsOf: url)
        let marker = try XCTUnwrap(data.range(of: Data("data".utf8)), "no data chunk")
        data.replaceSubrange(marker.upperBound ..< marker.upperBound + 4, with: [0, 0, 0, 0])
        data.replaceSubrange(4 ..< 8, with: [4, 0, 0, 0])
        try data.write(to: url)
    }

    /// Age every file past the in-progress guard, the way a crash does.
    private func backdate(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path,
            )
        }
    }
}
