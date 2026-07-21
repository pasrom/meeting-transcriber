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
        spy: ConsentSpy,
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
}
