import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// The in-progress marker's whole life: written before capture opens, dropped
/// again when the start never opened, and dropped only once a durable mix
/// exists. Crash recovery reads that marker as "this process died mid-
/// recording", so every one of these transitions decides whether a real
/// recording is rescued, lost, or resurrected as a duplicate.
///
/// Reachable at all because the recorder takes its staging directory and its
/// capture session as arguments. Without both, driving `start()` would open the
/// real hardware and write into the production staging directory that crash
/// recovery and the orphan scan walk.
@MainActor
final class DualSourceRecorderLifecycleTests: XCTestCase {
    // MARK: - Doubles

    /// A capture session that touches nothing: it throws what the test staged,
    /// records what the recorder asked for, and reports back the file the test
    /// wrote.
    private final class FakeCaptureSession: AudioCapturing {
        var startError: (any Error)?
        /// The mic track `stop()` reports, set by a test after `start()` has
        /// picked the URL and the test has written fixture audio there.
        var micTrack: URL?
        var appLevelDBFS: Double = -120
        var micLevelDBFS: Double = -120
        var appCaptureGaveUp = false
        var micCaptureGaveUp = false
        /// What the recorder asked the factory for, so a test can assert on the
        /// choices and write to the URLs it picked.
        var lastRequest: CaptureSessionRequest?

        func start() throws {
            if let startError { throw startError }
        }

        func stop() -> AudioCaptureResult {
            AudioCaptureResult(
                appAudioFileURL: nil, micAudioFileURL: micTrack,
                actualSampleRate: 16000, actualChannels: 1, micDelay: 0,
            )
        }
    }

    // MARK: - Helpers

    private func makeRecorder(dir: URL) -> (DualSourceRecorder, FakeCaptureSession) {
        let session = FakeCaptureSession()
        let recorder = DualSourceRecorder(recordingsDir: dir) { request in
            session.lastRequest = request
            return session
        }
        return (recorder, session)
    }

    /// Stems of the markers in `dir`, read through the same suffix rule the
    /// janitor and crash recovery use rather than a second copy of it.
    private func markerStems(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .compactMap { RecordingFileSuffix.stripInProgress(from: $0) }
    }

    /// Start a microphone-only recording and hand back the mic track's URL, so
    /// the test can stage what the session will report at `stop()`.
    private func startMicOnly(
        recorder: DualSourceRecorder,
        session: FakeCaptureSession,
    ) throws -> URL {
        try recorder.start(source: .micOnly)
        return try XCTUnwrap(session.lastRequest?.micOutputURL)
    }

    // MARK: - start

    func testStartMarksTheRecordingUnderTheSameStemAsItsTracks() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_start")
        let (recorder, session) = makeRecorder(dir: dir)

        let micURL = try startMicOnly(recorder: recorder, session: session)

        XCTAssertTrue(recorder.isRecording)
        let track = try XCTUnwrap(RecordingFileSuffix.stripSuffix(from: micURL.lastPathComponent))
        XCTAssertEqual(
            try markerStems(in: dir), [track.stem],
            "recovery pairs marker and tracks by stem, so a marker under any other name rescues nothing",
        )
    }

    /// The microphone-only shape (issue #633): no process tap is opened at all,
    /// which is not the same as a tap that captured nothing — the session
    /// treats a mic failure as terminal only when the mic is the whole
    /// recording.
    func testAMicrophoneOnlyRecordingOpensNoProcessTap() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_mic_only")
        let (recorder, session) = makeRecorder(dir: dir)

        try recorder.start(source: .micOnly)

        let request = try XCTUnwrap(session.lastRequest)
        XCTAssertNil(request.appOutputURL, "a tap would capture a meeting that is happening in the room")
        XCTAssertNotNil(request.micOutputURL)
        XCTAssertTrue(request.pids.isEmpty)
    }

    /// The mirror image: "No Microphone" opens the tap and no mic track.
    func testAnAppOnlyRecordingOpensNoMicrophone() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_app_only")
        let (recorder, session) = makeRecorder(dir: dir)

        // A PID no process holds: the tap-PID resolution then has no bundle to
        // enumerate and falls back to the root alone, with nothing to depend on
        // in whatever else is running on the machine.
        try recorder.start(source: .appOnly(pid: 999_999))

        let request = try XCTUnwrap(session.lastRequest)
        XCTAssertNotNil(request.appOutputURL)
        XCTAssertNil(request.micOutputURL)
        XCTAssertEqual(request.pids, [999_999])
    }

    /// A start that threw before capture opened is not an interrupted
    /// recording, and nothing else would ever clear its marker: `stop()` is
    /// unreachable with `isRecording` still false, and the janitor keys on
    /// tracks this start never created.
    func testAStartThatNeverOpenedLeavesNoMarkerBehind() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_start_failed")
        let (recorder, session) = makeRecorder(dir: dir)
        session.startError = RecorderError.noAudioData

        XCTAssertThrowsError(try recorder.start(source: .micOnly))

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(try markerStems(in: dir), [], "a start that never opened is not a crash")
    }

    // MARK: - stop

    func testStopDropsTheMarkerOnceTheMixExists() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_stop")
        let (recorder, session) = makeRecorder(dir: dir)
        let micURL = try startMicOnly(recorder: recorder, session: session)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micURL)
        session.micTrack = micURL

        let recording = try recorder.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.mixPath.path))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(
            try markerStems(in: dir), [],
            "a marker left beside a finished recording turns into a false crash on the next launch",
        )
    }

    /// A stop whose mix write fails has finished nothing. Keeping the marker is
    /// what lets the next launch re-mix from the surviving tracks — the same
    /// second chance the app-audio path has always had from its raw temp.
    func testAStopWhoseMixFailsKeepsTheMarkerForTheNextLaunch() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_stop_failed")
        let (recorder, session) = makeRecorder(dir: dir)
        let micURL = try startMicOnly(recorder: recorder, session: session)
        // Past the size guard, but not decodable audio: the mix fails after the
        // tracks have been read and before anything durable is written.
        try Data(repeating: 0xFF, count: 128).write(to: micURL)
        session.micTrack = micURL

        XCTAssertThrowsError(try recorder.stop())

        XCTAssertEqual(
            try markerStems(in: dir).count, 1,
            "dropping the marker here would strand a mic-only recording for good",
        )
    }

    // MARK: - Channel reporting

    /// The levels and the give-up flags the menu bar reads come from the live
    /// session. A level cannot say a channel was abandoned: one that fell
    /// silent may come back, one that gave up will not.
    func testTheRecorderReportsTheLiveSessionsChannelState() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_levels")
        let (recorder, session) = makeRecorder(dir: dir)
        // Each channel gets a different value from its sibling, so a forwarder
        // wired to the wrong one — or hardcoded to the no-session default —
        // fails rather than coinciding with the right answer.
        session.appLevelDBFS = -12
        session.micLevelDBFS = -30
        session.appCaptureGaveUp = true
        session.micCaptureGaveUp = false

        // Between recordings there is no session to ask, and silence plus "has
        // not given up" is the only safe answer: a spurious give-up would tell
        // the user a capture died that never ran.
        XCTAssertEqual(recorder.appLevelDBFS, -120, accuracy: 0.001)
        XCTAssertEqual(recorder.micLevelDBFS, -120, accuracy: 0.001)
        XCTAssertFalse(recorder.appCaptureGaveUp)
        XCTAssertFalse(recorder.micCaptureGaveUp)

        try recorder.start(source: .micOnly)

        XCTAssertEqual(recorder.appLevelDBFS, -12, accuracy: 0.001)
        XCTAssertEqual(recorder.micLevelDBFS, -30, accuracy: 0.001)
        XCTAssertTrue(recorder.appCaptureGaveUp)
        XCTAssertFalse(recorder.micCaptureGaveUp)
    }
}
