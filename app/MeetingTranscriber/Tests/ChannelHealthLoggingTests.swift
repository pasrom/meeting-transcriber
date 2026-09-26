import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// That each channel-health diagnostics line is actually written, and at the
/// point it claims to be. `ChannelHealthLogLineTests` pins what the lines say;
/// without these, deleting the call that writes one kept every test green.
@MainActor
final class ChannelHealthLoggingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let source = RecordingSource.forApp(pid: 4242, noMic: false)

    private func makeController() -> (ChannelHealthController, RecordingDiagnostics) {
        let log = RecordingDiagnostics()
        let controller = ChannelHealthController(
            notifier: RecordingNotifier(), debounceSeconds: { 30 }, indicatorEnabled: { false }, log: log,
        )
        return (controller, log)
    }

    func testStartingAndStoppingAWatchedRecordingIsLogged() {
        let (controller, log) = makeController()

        controller.start(source: source) { nil }
        controller.stop()

        XCTAssertEqual(
            log.lines(.notice, startingWith: "Channel health monitoring started"),
            [ChannelHealthController.startLogLine(channels: .micAndApp, window: 30)],
        )
        XCTAssertEqual(log.lines(.notice, startingWith: "Channel health monitoring stopped").count, 1)
    }

    func testAStopWithNoWatchedRecordingLogsNothing() {
        // `stop()` runs on every idle transition, so a line here would bury
        // the ones that matter.
        let (controller, log) = makeController()

        controller.stop()

        XCTAssertTrue(log.lines.isEmpty, "\(log.lines)")
    }

    func testASecondStartWhileRunningIsLoggedWithTheTopologyItReplaced() {
        let (controller, log) = makeController()
        controller.start(source: source) { nil }
        addTeardownBlock { controller.stop() }

        controller.start(source: .micOnly) { nil }

        XCTAssertEqual(
            log.lines(.notice, startingWith: "Channel health monitoring already running"),
            [ChannelHealthController.restartIgnoredLogLine(channels: .micOnly, previous: .micAndApp)],
        )
    }

    func testTheFirstTickAndAFaultAreEachLoggedOnceWhenTheyHappen() {
        let (controller, log) = makeController()
        controller.simulateStartForTests()
        let recorder = MockRecorder()
        recorder.micSignalAges = .unknown
        recorder.appLevelDBFS = -20

        controller.applyTick(recorder: recorder, now: t0)
        XCTAssertEqual(log.lines(.notice, startingWith: "Channel health first tick").count, 1)
        XCTAssertTrue(log.lines(.notice, startingWith: "Channel fault").isEmpty, "no verdict before the window")

        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(31))

        XCTAssertEqual(log.lines(.notice, startingWith: "Channel health first tick").count, 1)
        XCTAssertEqual(
            log.lines(.notice, startingWith: "Channel fault"),
            [ChannelHealthController.faultLogLine(channel: .mic, fault: .noBuffers, ages: .unknown, elapsed: 30, window: 30)],
        )
    }

    func testASilentRecordingEpisodeIsLoggedAtBothEnds() {
        let (controller, log) = makeController()
        controller.simulateStartForTests()
        // Both levels at the -120 default: silent on both channels.
        let recorder = MockRecorder()

        controller.applyTick(recorder: recorder, now: t0)
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))
        XCTAssertEqual(log.lines(.notice, startingWith: "Silent recording:").count, 1)
        XCTAssertTrue(log.lines(.notice, startingWith: "Silent recording recovered").isEmpty)

        recorder.micLevelDBFS = -20
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(31))

        XCTAssertEqual(
            log.lines(.notice, startingWith: "Silent recording recovered"),
            [ChannelHealthController.silentRecordingRecoveredLogLine(micDBFS: -20, appDBFS: -120)],
        )
    }

    func testTheStopLineSaysASilentEpisodeWasStillOpen() {
        let (controller, log) = makeController()
        controller.start(source: source) { nil }
        let recorder = MockRecorder()
        controller.applyTick(recorder: recorder, now: t0)
        controller.applyTick(recorder: recorder, now: t0.addingTimeInterval(30))

        controller.stop()

        let stopLines = log.lines(.notice, startingWith: "Channel health monitoring stopped")
        XCTAssertEqual(stopLines.count, 1)
        XCTAssertEqual(stopLines.first?.contains("recordingSilent=true"), true, "\(stopLines)")
    }
}
