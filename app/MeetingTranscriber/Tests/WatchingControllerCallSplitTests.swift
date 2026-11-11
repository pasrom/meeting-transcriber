@testable import MeetingTranscriber
import XCTest

/// A call split (the app moves on to another call within the end grace) driven
/// through `WatchingController`'s real auto-detect path, so the transition
/// handler and the recorder factory it wires are the production ones.
///
/// `WatchLoopTimingTests` proves the loop enters `.recording` once per call.
/// What it cannot show is what hangs on that transition in the controller: the
/// "Meeting Detected" notification and channel-health monitoring with fresh
/// fault latches.
///
/// Real time, because the controller builds its loop from `AppSettings`. The
/// poll interval is set to its one-second floor, so a split takes about one
/// poll.
@MainActor
final class WatchingControllerCallSplitTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "WatchingControllerCallSplitTests")
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// Always in a call; which one is up to the test. Changing `callID` while
    /// recording is a split, since the recorded call's ID is then gone and only
    /// a new one is active.
    private final class SwitchingCallDetector: MeetingDetecting {
        var callID = "call-A"

        func checkOnce() -> DetectedMeeting? {
            makeTestMeeting(pid: getpid())
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            true
        }

        func activeCalls(_: DetectedMeeting) -> ActiveCalls {
            .ids([callID])
        }

        func reset(appName _: String?) {}
    }

    /// Generous: a split takes about one one-second poll, and every wait below
    /// ends as soon as its condition holds.
    private let splitTimeout: Duration = .seconds(10)

    /// A recorder whose microphone has never delivered a buffer while the app
    /// channel carries signal, so channel health reports the mic in each call.
    private func makeRecorderWithDeadMic() -> MockRecorder {
        let recorder = makeMockRecorder()
        recorder.micSignalAges = .unknown
        recorder.appSignalAges = .deliveringSignalNow
        return recorder
    }

    private let deadMicBody = ChannelHealthController.faultMessage(
        channel: .mic, fault: .noBuffers, everCarriedSignal: false,
    )

    private func count(_ notifier: RecordingNotifier, _ title: String, body: String? = nil) -> Int {
        notifier.calls.count { $0.title == title && (body == nil || $0.body == body) }
    }

    private func waitUntilRecording(_ controller: WatchingController) async {
        await waitFor({ controller.watchLoop?.state == .recording }, timeout: splitTimeout)
        XCTAssertEqual(controller.watchLoop?.state, .recording, "precondition: the first call is recording")
    }

    /// Everything that hangs on entering `.recording` runs again for the second
    /// call: it is announced, and its channel health starts from scratch. A
    /// microphone that is dead in both calls is reported in both, which it is
    /// not when the second call inherits the first call's latched fault.
    func testTheSecondCallOfASplitIsAnnouncedAndMonitoredAfresh() async {
        let detector = SwitchingCallDetector()
        let notifier = RecordingNotifier()
        let controller = makeWatchingController(
            logDir: tmpDir, notifier: notifier, permissionHealth: .allHealthy,
            makeDetector: { detector },
            makeRecorder: { self.makeRecorderWithDeadMic() },
        )
        controller.settings.pollInterval = 1
        let started = await controller.startWatching()
        addTeardownBlock { _ = await controller.stopWatching() }
        XCTAssertEqual(started, .changed, "precondition")
        await waitUntilRecording(controller)

        await waitFor({ self.count(notifier, "Capture Channel Silent", body: self.deadMicBody) == 1 }, timeout: splitTimeout)
        XCTAssertEqual(count(notifier, "Meeting Detected"), 1, "precondition: the first call was announced")
        XCTAssertEqual(count(notifier, "Capture Channel Silent", body: deadMicBody), 1, "precondition: the first call's dead mic")

        detector.callID = "call-B"
        await waitFor({ self.count(notifier, "Meeting Detected") == 2 }, timeout: splitTimeout)
        XCTAssertEqual(count(notifier, "Meeting Detected"), 2, "the second call must be announced")
        await waitFor({ self.count(notifier, "Capture Channel Silent", body: self.deadMicBody) == 2 }, timeout: splitTimeout)
        XCTAssertEqual(
            count(notifier, "Capture Channel Silent", body: deadMicBody), 2,
            "the second call's dead mic must be reported, not hidden by the first call's latch",
        )
    }
}
