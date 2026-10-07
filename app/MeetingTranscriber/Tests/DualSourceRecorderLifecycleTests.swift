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
        /// The raw app temp `stop()` reports; nil for the mic-only tests.
        var appTrack: URL?
        var appLevelDBFS: Double = -120
        var micLevelDBFS: Double = -120
        var appCaptureGaveUp = false
        var micCaptureGaveUp = false
        var appSilentTrackWatchdogGaveUp = false
        var appSignalAges: ChannelSignalAges = .unknown
        var micSignalAges: ChannelSignalAges = .unknown
        /// The configuration the recorder handed the factory, so a test can
        /// assert on the choices and write to the URLs it picked.
        var lastConfiguration: AudioCaptureConfiguration?

        func start() throws {
            if let startError { throw startError }
        }

        func stop() -> AudioCaptureResult {
            AudioCaptureResult(
                appAudioFileURL: appTrack, micAudioFileURL: micTrack,
                actualSampleRate: 16000, actualChannels: 1, micDelay: 0,
            )
        }
    }

    // MARK: - Helpers

    private func makeRecorder(dir: URL) -> (DualSourceRecorder, FakeCaptureSession) {
        let session = FakeCaptureSession()
        let recorder = DualSourceRecorder(recordingsDir: dir) { configuration in
            session.lastConfiguration = configuration
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
        return try XCTUnwrap(session.lastConfiguration?.micOutputURL)
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

        let configuration = try XCTUnwrap(session.lastConfiguration)
        XCTAssertNil(configuration.appOutputURL, "a tap would capture a meeting that is happening in the room")
        XCTAssertNotNil(configuration.micOutputURL)
        XCTAssertTrue(configuration.pids.isEmpty)
    }

    /// The mirror image: "No Microphone" opens the tap and no mic track.
    func testAnAppOnlyRecordingOpensNoMicrophone() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_app_only")
        let (recorder, session) = makeRecorder(dir: dir)

        // A PID no process holds: the tap-PID resolution then has no bundle to
        // enumerate and falls back to the root alone, with nothing to depend on
        // in whatever else is running on the machine.
        try recorder.start(source: .appOnly(pid: 999_999))

        let configuration = try XCTUnwrap(session.lastConfiguration)
        XCTAssertNotNil(configuration.appOutputURL)
        XCTAssertNil(configuration.micOutputURL)
        XCTAssertEqual(configuration.pids, [999_999])
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

    /// The quit's stop moves the file work off the main actor and must still
    /// finish a recording exactly as `stop()` does: a mix on disk, the
    /// recorder idle, the marker gone.
    func testStopOffMainFinishesTheRecordingLikeStop() async throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_stop_off_main")
        let (recorder, session) = makeRecorder(dir: dir)
        let micURL = try startMicOnly(recorder: recorder, session: session)
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.2, count: 16000), sampleRate: 16000, url: micURL)
        session.micTrack = micURL

        let recording = try await recorder.stopOffMain()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.mixPath.path))
        XCTAssertEqual(recording.micPath, micURL)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(try markerStems(in: dir), [])
    }

    /// `stopOffMain` is only worth having if the file work really leaves the
    /// main thread: the protocol's default is the synchronous `stop()`, so a
    /// recorder without its own version would pass every other test. Measured
    /// by a main-actor ticker: while the stop runs, the ticker keeps ticking
    /// only if the main thread is free.
    func testStopOffMainLeavesTheMainThreadFreeWhileItMixes() async throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_stop_off_main_free")
        let (recorder, session) = makeRecorder(dir: dir)
        let micURL = try startMicOnly(recorder: recorder, session: session)
        // Both tracks, so the stop really mixes, and long enough that it takes
        // a measurable time in a debug build.
        let samples = [Float](repeating: 0.2, count: 16000 * 120)
        try AudioMixer.saveWAV(samples: samples, sampleRate: 16000, url: micURL)
        session.micTrack = micURL
        let appTemp = dir.appendingPathComponent("app_temp" + RecordingFileSuffix.appRaw)
        try writeRawFloat32(samples, to: appTemp)
        session.appTrack = appTemp

        let ticks = MainThreadTicker()
        let ticker = Task { await ticks.run() }
        await Task.yield()
        let start = ContinuousClock.now
        _ = try await recorder.stopOffMain()
        let elapsed = ContinuousClock.now - start
        ticks.ticking = false
        await ticker.value
        let longestGap = ticks.longestGap

        XCTAssertGreaterThan(elapsed, .milliseconds(100), "test premise: the stop was too fast to tell")
        XCTAssertLessThan(
            longestGap, elapsed / 2,
            "the main thread was held for \(longestGap) of a \(elapsed) stop",
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

    /// The levels, the give-up flags and the signal ages all come from the live
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
        session.appSilentTrackWatchdogGaveUp = true
        session.appSignalAges = ChannelSignalAges(secondsSinceLastBuffer: 1, secondsSinceLastEnergy: 2)
        session.micSignalAges = ChannelSignalAges(secondsSinceLastBuffer: 3, secondsSinceLastEnergy: 4)

        // Between recordings there is no session to ask, and silence plus "has
        // not given up" is the only safe answer: a spurious give-up would tell
        // the user a capture died that never ran.
        XCTAssertEqual(recorder.appLevelDBFS, -120, accuracy: 0.001)
        XCTAssertEqual(recorder.micLevelDBFS, -120, accuracy: 0.001)
        XCTAssertFalse(recorder.appCaptureGaveUp)
        XCTAssertFalse(recorder.micCaptureGaveUp)
        XCTAssertFalse(recorder.appSilentTrackWatchdogGaveUp)
        // Never opened, not "opened and long silent": the fault monitor reads
        // the two apart, so the no-session answer has to be the absent one.
        XCTAssertEqual(recorder.appSignalAges, .unknown)
        XCTAssertEqual(recorder.micSignalAges, .unknown)

        try recorder.start(source: .micOnly)

        XCTAssertEqual(recorder.appLevelDBFS, -12, accuracy: 0.001)
        XCTAssertEqual(recorder.micLevelDBFS, -30, accuracy: 0.001)
        XCTAssertTrue(recorder.appCaptureGaveUp)
        XCTAssertFalse(recorder.micCaptureGaveUp)
        XCTAssertTrue(recorder.appSilentTrackWatchdogGaveUp)
        // Its own flag, not the give-up one read under another name.
        session.appCaptureGaveUp = false
        XCTAssertTrue(recorder.appSilentTrackWatchdogGaveUp)
        session.appCaptureGaveUp = true
        XCTAssertEqual(recorder.appSignalAges.secondsSinceLastBuffer, 1)
        XCTAssertEqual(recorder.appSignalAges.secondsSinceLastEnergy, 2)
        XCTAssertEqual(recorder.micSignalAges.secondsSinceLastBuffer, 3)
        XCTAssertEqual(recorder.micSignalAges.secondsSinceLastEnergy, 4)
    }

    // MARK: - Silent-track watchdog option (issue #672)

    /// The option has to travel from the setting to the capture configuration
    /// a recording opens with. Two hops live in this module: the recorder
    /// factory reads the setting into the recorder, and the recorder writes it
    /// into `AudioCaptureConfiguration`. The hop from there into the tap is
    /// pinned in AudioTapLib. A dropped hop would leave the switch reading "on"
    /// while every recording ran without the watchdog.
    func testTheRecorderOpensWithoutTheWatchdogByDefault() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_watchdog_default")
        let (recorder, session) = makeRecorder(dir: dir)
        try recorder.start(source: .micOnly)
        XCTAssertEqual(session.lastConfiguration?.silentTrackWatchdog, false)
    }

    func testTheRecorderHandsTheWatchdogToTheCapture() throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_watchdog_on")
        let (recorder, session) = makeRecorder(dir: dir)
        recorder.silentTrackWatchdogEnabled = true
        try recorder.start(source: .micOnly)
        XCTAssertEqual(session.lastConfiguration?.silentTrackWatchdog, true)
    }

    /// The setting reaches a recording that `WatchingController` starts, read
    /// when that recording starts rather than when watching was set up.
    func testTheSettingReachesARecordingTheControllerStarts() async throws {
        let dir = try makeTempDirectory(prefix: "lifecycle_watchdog_controller")
        let (recorder, session) = makeRecorder(dir: dir.appendingPathComponent("staging", isDirectory: true))
        let controller = makeWatchingController(
            logDir: dir, permissionHealth: .allHealthy,
            // Labelled on purpose: as a trailing closure it would bind to the
            // first closure parameter, not to `makeRecorder`.
            // swiftlint:disable:next trailing_closure
            makeRecorder: { recorder },
        )
        controller.settings.silentTrackWatchdogEnabled = true

        // This process, so the target is alive for the length of the test.
        controller.startManualRecording(pid: getpid(), appName: "Chrome", title: "Standup")
        addTeardownBlock { controller.stopManualRecording() }
        await waitFor(controller.watchLoop?.state == .recording, timeout: .seconds(2))

        XCTAssertEqual(session.lastConfiguration?.silentTrackWatchdog, true)
    }
}

/// Ticks on the main actor and records the longest gap between two ticks,
/// which is how long the main thread was held.
@MainActor
private final class MainThreadTicker {
    var ticking = true
    private(set) var longestGap = Duration.zero

    func run() async {
        var last = ContinuousClock.now
        // Measured after each wake, before the stop flag is read, so the gap
        // the stop caused is counted even when it ends the loop.
        repeat {
            try? await Task.sleep(for: .milliseconds(5))
            let now = ContinuousClock.now
            longestGap = max(longestGap, now - last)
            last = now
        } while ticking
    }
}
