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

    /// A start that threw before capture opened leaves a marker and no tracks.
    /// Nothing else removes one: `stop()` never ran, and recovery fails on
    /// `noAudioData` every launch and every watch-start, warning each time.
    func testAMarkerFromAStartThatCapturedNothingIsCleanedUp() throws {
        let dir = try makeTempDirectory(prefix: "marker_no_tracks")
        let stem = "20260311_200000"
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        try backdate([marker])

        DualSourceRecorder.cleanupTempFiles(recordingsDir: dir, reapMarkersWrittenBefore: Date())

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a marker with no audio is a dead end")
    }

    /// Same dead end one step later: the mic file exists but never received a
    /// buffer, so it is a bare header and there is still nothing to rescue.
    func testAMarkerBesideATrackThatNeverGotAudioIsCleanedUp() throws {
        let dir = try makeTempDirectory(prefix: "marker_empty_track")
        let stem = "20260311_210000"
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: [], sampleRate: 16000, url: micWav)
        try backdate([marker, micWav])

        DualSourceRecorder.cleanupTempFiles(recordingsDir: dir, reapMarkersWrittenBefore: Date())

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "an empty track rescues nothing")
    }

    /// The control case. A janitor that deleted every old marker would pass the
    /// two tests above and quietly throw away the recordings this whole
    /// mechanism exists to rescue, since it runs on the same launch, right
    /// after recovery.
    func testCleanupKeepsAMarkerWhoseTrackStillHoldsAudio() throws {
        let dir = try makeTempDirectory(prefix: "marker_with_audio")
        let stem = "20260311_220000"
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        try backdate([marker, micWav])

        DualSourceRecorder.cleanupTempFiles(recordingsDir: dir, reapMarkersWrittenBefore: Date())

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "the marker of a rescuable recording must survive the cleanup pass",
        )
    }

    /// A recording that started moments ago has a marker and no tracks yet,
    /// which is the same shape on disk as a failed start. Only age tells them
    /// apart, and the queue rebuild that runs this pass fires on watch-start,
    /// immediately before the loop may begin recording.
    func testCleanupKeepsAFreshMarker() throws {
        let dir = try makeTempDirectory(prefix: "marker_fresh")
        let marker = DualSourceRecorder.inProgressMarker(stem: "20260311_230000", in: dir)
        try Data().write(to: marker)

        DualSourceRecorder.cleanupTempFiles(recordingsDir: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "a recording may have just started")
    }

    /// THE guard for this pass. A marker is written once at start and never
    /// touched, so its age is simply how long the recording has been running:
    /// no age window survives a long one. A mic wedged mid-capture (issue #588)
    /// delivers no buffers either, so its track stays at bare-header size and
    /// reads as worthless. Reaping there strands the recording for good, since
    /// a later crash then leaves a lone mic track that neither crash recovery
    /// nor the orphan scan will look at. Only "written before this process
    /// existed" can tell a foreign leftover from our own running capture.
    func testCleanupKeepsAnOldMarkerWrittenByTheRunningProcess() throws {
        let dir = try makeTempDirectory(prefix: "marker_ours")
        let stem = "20260311_250000"
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: [], sampleRate: 16000, url: micWav) // wedged: nothing flushed
        try backdate([marker, micWav]) // and running long enough to look ancient

        DualSourceRecorder.cleanupTempFiles(
            recordingsDir: dir, reapMarkersWrittenBefore: Date(timeIntervalSinceNow: -300),
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "a marker younger than the process that would reap it is a live recording, not a leftover",
        )
    }

    /// The threshold pinned from the side that loses data. Between an empty
    /// track and a full second of audio there is room to raise it without any
    /// test noticing, and every byte of that room is somebody's recording.
    func testCleanupKeepsAMarkerWhoseTrackHoldsASingleFrame() throws {
        let dir = try makeTempDirectory(prefix: "marker_one_frame")
        let stem = "20260311_260000"
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: [0.2], sampleRate: 16000, url: micWav)
        try backdate([marker, micWav])

        DualSourceRecorder.cleanupTempFiles(recordingsDir: dir, reapMarkersWrittenBefore: Date())

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "one frame is still audio, and the marker is what gets it rescued",
        )
    }

    /// The app-audio half of the same predicate, and the case that makes it
    /// load-bearing. The pass deletes stale raw temps before it looks at
    /// markers, so a temp still present here is one being written right now:
    /// a live recording belonging to another instance of the app, whose marker
    /// predates ours. Reaping it would strip a running capture of its only
    /// crash signal.
    func testCleanupKeepsAMarkerBesideALiveRawAppTemp() throws {
        let dir = try makeTempDirectory(prefix: "marker_raw_temp")
        let stem = "20260311_270000"
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        try backdate([marker])
        let appTmp = dir.appendingPathComponent(stem + RecordingFileSuffix.appRaw)
        try writeRawFloat32([Float](repeating: 0.3, count: 16000), to: appTmp) // fresh: still being written

        DualSourceRecorder.cleanupTempFiles(recordingsDir: dir, reapMarkersWrittenBefore: Date())

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "a temp that survived the pass above is a live writer, not a leftover",
        )
    }

    /// A marker beside a finished mix is stale, not a crash. Left alone it
    /// would become a false crash the moment the finished job moves the mix
    /// into the output folder, leaving marker plus mic track behind.
    func testAMarkerBesideAFinishedMixIsReaped() throws {
        let dir = try makeTempDirectory(prefix: "marker_finished")
        let stem = "20260311_280000"
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micWav)
        let mix = dir.appendingPathComponent(stem + RecordingFileSuffix.mix)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: mix)
        try backdate([marker, micWav, mix])

        DualSourceRecorder.cleanupTempFiles(recordingsDir: dir, reapMarkersWrittenBefore: Date())

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "a recording with a mix is finished, whatever its marker says",
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

    /// An empty track must never become a mix. Recovery reaches this stem
    /// before the janitor does, so a `buildRecording` that read zero samples as
    /// audio would write a silent `_mix.wav` — and the orphan scan enqueues
    /// every untracked mix, so a start that captured nothing would come back as
    /// a meeting to transcribe.
    func testAStemWhoseTrackNeverGotAudioProducesNoMix() throws {
        let dir = try makeTempDirectory(prefix: "crash_empty_track_mix")
        let stem = "20260311_250000"
        let marker = DualSourceRecorder.inProgressMarker(stem: stem, in: dir)
        try Data().write(to: marker)
        let micWav = dir.appendingPathComponent(stem + RecordingFileSuffix.mic)
        try AudioMixer.saveWAV(samples: [], sampleRate: 16000, url: micWav)
        try backdate([marker, micWav])

        let count = DualSourceRecorder.recoverCrashedRecordings(in: dir)

        XCTAssertEqual(count, 0, "there was nothing to recover")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(stem + RecordingFileSuffix.mix).path),
            "a silent mix would be picked up by the orphan scan and transcribed as a meeting",
        )
    }

    /// A marker whose tracks are both gone: a start that threw before either
    /// file was created, or a stem someone cleaned up by hand. Recovery has
    /// nothing to rebuild from and must say so, because its caller counts a
    /// return as a rescued recording and hands the mix path on.
    func testRecoveringAStemWithNoTracksAtAllThrows() throws {
        let dir = try makeTempDirectory(prefix: "crash_no_tracks")

        XCTAssertThrowsError(
            try DualSourceRecorder.recoverCrashedRecording(stem: "20260311_260000", in: dir),
        ) { error in
            guard case RecorderError.noAudioData = error else {
                return XCTFail("expected noAudioData, got \(error)")
            }
        }
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
