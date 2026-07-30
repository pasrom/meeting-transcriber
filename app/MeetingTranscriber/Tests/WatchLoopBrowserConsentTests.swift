@testable import MeetingTranscriber
import XCTest

/// The `WatchLoop` consent gate for browser meetings (issue #503): meetings
/// whose pattern requires consent prompt before recording instead of
/// auto-starting, and a decline must not re-prompt on every poll. Driven
/// through the real `start()`/`watchLoop()` path so the gate is exercised in
/// place, not via a widened-visibility hook.
@MainActor
final class WatchLoopBrowserConsentTests: XCTestCase {
    /// Detector that always reports one meeting, active.
    private final class FixedDetector: MeetingDetecting {
        let meeting: DetectedMeeting
        init(_ meeting: DetectedMeeting) {
            self.meeting = meeting
        }

        func checkOnce() -> DetectedMeeting? {
            meeting
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            true
        }

        func reset(appName _: String?) {}
    }

    /// Counting consent responder — an `AppNotifying` whose `askToRecord` the
    /// `WatchLoop` consent gate calls. Records how often the user was prompted.
    private final class ConsentSpy: AppNotifying {
        private(set) var calls = 0
        let response: Bool
        init(response: Bool) {
            self.response = response
        }

        func notify(title _: String, body _: String) {}

        // swiftlint:disable async_without_await
        @MainActor
        func askToRecord(title _: String, body _: String) async -> Bool {
            calls += 1
            return response
        }
        // swiftlint:enable async_without_await
    }

    /// Detector whose reported meeting the test can swap mid-run, so a second
    /// meeting can appear while the first one's consent prompt is still parked.
    private final class SwappableDetector: MeetingDetecting {
        var meeting: DetectedMeeting?
        init(_ meeting: DetectedMeeting?) {
            self.meeting = meeting
        }

        func checkOnce() -> DetectedMeeting? {
            meeting
        }

        func isMeetingActive(_: DetectedMeeting) -> Bool {
            true
        }

        func reset(appName _: String?) {}
    }

    /// Consent responder that parks, like the real prompt does: `askToRecord`
    /// suspends until someone answers. The real one waits up to 60 s for a
    /// notification the user may never see.
    private final class ParkingConsentSpy: AppNotifying {
        private(set) var calls = 0
        /// Every answer handed to a parked prompt, in order.
        private(set) var resolutions: [Bool] = []
        private var continuation: CheckedContinuation<Bool, Never>?

        var isParked: Bool {
            continuation != nil
        }

        func notify(title _: String, body _: String) {}

        @MainActor
        func askToRecord(title _: String, body _: String) async -> Bool {
            calls += 1
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        /// Same contract as `NotificationManager.resolveBrowserConsent`: true
        /// when a prompt was actually waiting.
        func resolveBrowserConsent(granted: Bool) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            resolutions.append(granted)
            continuation.resume(returning: granted)
            return true
        }
    }

    private func browserMeeting() -> DetectedMeeting {
        DetectedMeeting(
            pattern: .chromeBrowser,
            windowTitle: "Google Chrome Call",
            ownerName: "Google Chrome",
            windowPID: 5632,
        )
    }

    private func nativeMeeting() -> DetectedMeeting {
        DetectedMeeting(
            pattern: .zoom,
            windowTitle: "Zoom Meeting",
            ownerName: "zoom.us",
            windowPID: 4321,
        )
    }

    private func makeLoop(
        detector: any MeetingDetecting,
        spy: any AppNotifying,
        consentPolicy: BrowserConsentPolicy = BrowserConsentPolicy(),
    ) -> (WatchLoop, MockRecorder) {
        let recorder = MockRecorder()
        recorder.mixPath = URL(fileURLWithPath: "/tmp/test_mix_\(UUID().uuidString).wav")
        let loop = WatchLoop(
            detector: detector,
            recorderFactory: { recorder },
            pollInterval: 0.05,
            endGracePeriod: 0.05,
            notifier: spy,
            consentPolicy: consentPolicy,
        )
        loop.permissionChecker = {
            HealthCheckResult(screenRecording: .healthy, microphone: .healthy)
        }
        return (loop, recorder)
    }

    func testBrowserMeetingRecordsWhenConsentGranted() async {
        let spy = ConsentSpy(response: true)
        let (loop, recorder) = makeLoop(detector: FixedDetector(browserMeeting()), spy: spy)
        loop.start()
        await waitFor(recorder.startCalled)
        XCTAssertTrue(recorder.startCalled, "granted consent must start recording")
        XCTAssertGreaterThanOrEqual(spy.calls, 1, "the user must have been prompted")
        loop.stop()
    }

    func testBrowserMeetingNotRecordedWhenConsentDenied() async {
        let spy = ConsentSpy(response: false)
        let (loop, recorder) = makeLoop(detector: FixedDetector(browserMeeting()), spy: spy)
        loop.start()
        // Well within the default 60 s decline cooldown: several polls happen,
        // but the prompt must fire once and recording must never start.
        await waitFor(spy.calls >= 1)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(recorder.startCalled, "declined consent must not record")
        XCTAssertEqual(spy.calls, 1, "a decline must suppress re-prompts within the cooldown")
        loop.stop()
    }

    func testNativeMeetingNeverPromptsAndAutoStarts() async {
        let spy = ConsentSpy(response: false) // would block recording IF consulted
        let (loop, recorder) = makeLoop(detector: FixedDetector(nativeMeeting()), spy: spy)
        loop.start()
        await waitFor(recorder.startCalled)
        XCTAssertTrue(recorder.startCalled, "native meetings keep auto-start")
        XCTAssertEqual(spy.calls, 0, "native meetings must never consult the consent prompt")
        loop.stop()
    }

    func testDeclinedBrowserMeetingRePromptsAfterCooldown() async {
        let spy = ConsentSpy(response: false)
        let (loop, recorder) = makeLoop(
            detector: FixedDetector(browserMeeting()),
            spy: spy,
            consentPolicy: BrowserConsentPolicy(cooldown: 0.15),
        )
        loop.start()
        // With a 0.15 s cooldown and 0.05 s polls, a decline suppresses a few
        // polls, then the prompt re-appears — so calls climb past one over time.
        await waitFor(spy.calls >= 2, timeout: .seconds(2))
        XCTAssertGreaterThanOrEqual(spy.calls, 2, "prompt must re-appear once the cooldown elapses")
        XCTAssertFalse(recorder.startCalled)
        loop.stop()
    }

    // MARK: - A parked prompt must not stop the world (issue #543)

    /// The prompt is a notification the user may never see, and it stays open
    /// for `consentPromptTimeout`. While it was awaited inline in the poll
    /// loop, `checkOnce()` was not called at all for that minute: a Teams or
    /// Zoom call starting in that window went unrecorded. Worse, Google Meet
    /// raises the same WebRTC assertion on a page you cannot even join, so a
    /// failed join froze native detection for a minute.
    func testParkedConsentPromptDoesNotBlockANativeMeeting() async {
        let spy = ParkingConsentSpy()
        let detector = SwappableDetector(browserMeeting())
        let (loop, recorder) = makeLoop(detector: detector, spy: spy)
        loop.start()

        await waitFor(spy.isParked)
        XCTAssertFalse(recorder.startCalled, "nothing may record while the question is open")

        // The browser call is still going, but the user has now joined a Zoom
        // call as well. That one needs no consent and must start immediately.
        detector.meeting = nativeMeeting()
        await waitFor(recorder.startCalled, timeout: .seconds(3))
        XCTAssertTrue(recorder.startCalled, "a native meeting must record while consent is still parked")
        XCTAssertTrue(spy.isParked, "and the browser prompt must still be waiting for its answer")

        _ = spy.resolveBrowserConsent(granted: false)
        loop.stop()
    }

    /// Only one prompt per parked question. The WebRTC assertion re-detects the
    /// same call every poll, so a loop that no longer waits for the answer would
    /// otherwise post a fresh prompt every couple of seconds.
    func testParkedPromptIsNotRepostedOnEveryPoll() async {
        let spy = ParkingConsentSpy()
        let (loop, _) = makeLoop(detector: SwappableDetector(browserMeeting()), spy: spy)
        loop.start()

        await waitFor(spy.isParked)
        try? await Task.sleep(nanoseconds: 300_000_000) // several 0.05 s polls
        XCTAssertEqual(spy.calls, 1, "a parked prompt must not be re-posted while it waits")

        _ = spy.resolveBrowserConsent(granted: false)
        loop.stop()
    }

    /// Answering the parked prompt starts the recording it was asked about.
    func testGrantingAParkedPromptStartsTheRecording() async {
        let spy = ParkingConsentSpy()
        let (loop, recorder) = makeLoop(detector: SwappableDetector(browserMeeting()), spy: spy)
        loop.start()

        await waitFor(spy.isParked)
        XCTAssertFalse(recorder.startCalled)

        _ = spy.resolveBrowserConsent(granted: true)
        await waitFor(recorder.startCalled, timeout: .seconds(3))
        XCTAssertTrue(recorder.startCalled, "a granted prompt must still record")
        loop.stop()
    }

    /// Stopping the watch loop answers a parked prompt as a decline. Otherwise
    /// the question outlives the thing it was asked about: watching is off, yet
    /// a notification is still sitting there offering to record.
    func testStopResolvesAParkedPromptAsADecline() async {
        let spy = ParkingConsentSpy()
        let (loop, recorder) = makeLoop(detector: SwappableDetector(browserMeeting()), spy: spy)
        loop.start()

        await waitFor(spy.isParked)
        loop.stop()

        await waitFor(!spy.resolutions.isEmpty)
        XCTAssertEqual(spy.resolutions, [false], "stopping must decline, never grant")
        XCTAssertFalse(recorder.startCalled)
    }
}
