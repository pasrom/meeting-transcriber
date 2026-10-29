@testable import MeetingTranscriber
import XCTest

/// The microphone picker and "No Microphone" are read when a recording starts,
/// not when the loop was built (issue #706). A loop lives as long as watching
/// does, so a value frozen at construction kept the old device on every
/// recording until watching was restarted.
@MainActor
final class WatchLoopMicSettingsTests: XCTestCase {
    /// Stand-in for `AppSettings`: the loop reads it through closures, the
    /// same way `WatchingController` wires the real one.
    private final class MicSettings {
        var noMic = false
        var micDeviceUID: String?
    }

    /// `whileBuildingRecorder` runs inside the recorder factory, which both
    /// start paths await after deciding the source: the window in which a
    /// settings change could split one recording across two versions.
    private func makeLoop(
        _ settings: MicSettings,
        detector: any MeetingDetecting = makeSilentDetector(),
        whileBuildingRecorder: @escaping () -> Void = {},
    ) -> (WatchLoop, MockRecorder) {
        let recorder = makeMockRecorder()
        let noMic: () -> Bool = { settings.noMic }
        let micDeviceUID: () -> String? = { settings.micDeviceUID }
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: {
                whileBuildingRecorder()
                return recorder
            },
            pollInterval: 0.05,
            endGracePeriod: 0.1,
            noMic: noMic,
            micDeviceUID: micDeviceUID,
        )
        loop.permissionChecker = { .allHealthy }
        return (loop, recorder)
    }

    func testManualRecordingReadsMicSettingsAtStart() async throws {
        let settings = MicSettings()
        settings.micDeviceUID = "first-mic"
        let (loop, recorder) = makeLoop(settings)

        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")
        XCTAssertEqual(recorder.capturedSource, .appAndMic(pid: 42))
        XCTAssertEqual(recorder.capturedMicDeviceUID, "first-mic")
        loop.stopManualRecording()

        settings.noMic = true
        settings.micDeviceUID = "second-mic"
        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        XCTAssertEqual(recorder.capturedSource, .appOnly(pid: 42), "a changed No Microphone setting must reach the next recording")
        XCTAssertEqual(recorder.capturedMicDeviceUID, "second-mic", "a changed microphone pick must reach the next recording")
    }

    /// Same contract on the auto-detected path, which is the one a watching
    /// user actually hits.
    func testDetectedMeetingReadsMicSettingsAtStart() async throws {
        let settings = MicSettings()
        settings.noMic = true
        settings.micDeviceUID = "first-mic"
        let (loop, recorder) = makeLoop(settings, detector: ImmediatelyInactiveDetector())

        try await loop.handleMeeting(makeTestMeeting(pid: 4242))
        XCTAssertEqual(recorder.capturedSource, .appOnly(pid: 4242))
        XCTAssertEqual(recorder.capturedMicDeviceUID, "first-mic")

        settings.noMic = false
        settings.micDeviceUID = nil
        try await loop.handleMeeting(makeTestMeeting(pid: 4242))

        XCTAssertEqual(recorder.capturedSource, .appAndMic(pid: 4242))
        XCTAssertNil(recorder.capturedMicDeviceUID, "switching back to the system default must reach the next recording")
    }

    /// Reading the setting live must not reach into a recording that is
    /// already running: its channels were opened with the old value, and the
    /// channel-health wiring has to keep describing those.
    func testChangingNoMicDuringAManualRecordingLeavesItsSourceAlone() async throws {
        let settings = MicSettings()
        let (loop, _) = makeLoop(settings)

        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }
        settings.noMic = true

        XCTAssertEqual(loop.activeRecordingSource, .appAndMic(pid: 42))
    }

    func testChangingNoMicDuringADetectedMeetingLeavesItsSourceAlone() async throws {
        let settings = MicSettings()
        settings.noMic = true
        let (loop, _) = makeLoop(settings, detector: ImmediatelyInactiveDetector())

        var sourceWhileRecording: RecordingSource?
        loop.onStateChange = { [weak loop] _, new in
            guard new == .recording else { return }
            settings.noMic = false
            sourceWhileRecording = loop?.activeRecordingSource
        }
        try await loop.handleMeeting(makeTestMeeting(pid: 4242))

        XCTAssertEqual(sourceWhileRecording, .appOnly(pid: 4242))
    }

    /// One recording gets one version of the settings: a change that lands
    /// while the start awaits must not pair the old "No Microphone" choice
    /// with the new device, or the other way round.
    func testManualRecordingReadsBothMicSettingsBeforeItAwaits() async throws {
        let settings = MicSettings()
        settings.micDeviceUID = "first-mic"
        let (loop, recorder) = makeLoop(settings) {
            settings.noMic = true
            settings.micDeviceUID = "second-mic"
        }

        try await loop.startManualRecording(pid: 42, appName: "Chrome", title: "Meeting")
        defer { loop.stop() }

        XCTAssertEqual(recorder.capturedSource, .appAndMic(pid: 42))
        XCTAssertEqual(recorder.capturedMicDeviceUID, "first-mic")
    }

    func testDetectedMeetingReadsBothMicSettingsBeforeItAwaits() async throws {
        let settings = MicSettings()
        settings.micDeviceUID = "first-mic"
        let (loop, recorder) = makeLoop(settings, detector: ImmediatelyInactiveDetector()) {
            settings.noMic = true
            settings.micDeviceUID = "second-mic"
        }

        try await loop.handleMeeting(makeTestMeeting(pid: 4242))

        XCTAssertEqual(recorder.capturedSource, .appAndMic(pid: 4242))
        XCTAssertEqual(recorder.capturedMicDeviceUID, "first-mic")
    }

    /// The stored source is dropped when the recording ends, so a later start
    /// path that forgot to set it would read nil, not the previous recording.
    func testTheStoredSourceIsDroppedWhenTheRecordingEnds() async throws {
        let (loop, _) = makeLoop(MicSettings())

        try await loop.startMicrophoneRecording()
        XCTAssertEqual(loop.recordingSource, .micOnly)
        loop.stopManualRecording()

        XCTAssertNil(loop.recordingSource)
    }
}
