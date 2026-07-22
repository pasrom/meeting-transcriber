@testable import MeetingTranscriber
import XCTest

/// Google Meet detection: a Chromium browser's WebRTC power assertion is only
/// trusted when an in-call Meet tab title confirms it (`requiresWindowConfirmation`
/// + `strictTitleMatch`). Split into its own file — `PowerAssertionDetectorTests`
/// is at the `type_body_length` cap.
final class GoogleMeetDetectionTests: XCTestCase {
    private func win(owner: String, title: String?, pid: Int32 = 4242) -> [String: Any] {
        var w: [String: Any] = ["kCGWindowOwnerName": owner, "kCGWindowOwnerPID": pid]
        if let title { w["kCGWindowName"] = title }
        return w
    }

    private func meetDetector(
        processName: String = "Brave Browser",
        windows: @escaping () -> [[String: Any]],
    ) -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 4242,
                processName: processName,
                assertName: "WebRTC has active PeerConnections",
                assertType: "PreventUserIdleSystemSleep",
            )
        }
        detector.windowListProvider = windows
        return detector
    }

    // MARK: - Detection

    func testDetectsMeetCallInBrave() {
        let detector = meetDetector {
            [self.win(owner: "Brave Browser", title: "Meet – abc-defg-hij")]
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Google Meet")
        XCTAssertEqual(result?.windowTitle, "Meet – abc-defg-hij")
        XCTAssertEqual(result?.ownerName, "Brave Browser")
        XCTAssertEqual(result?.windowPID, 4242)
    }

    func testDetectsMeetCallInChrome() {
        let detector = meetDetector(processName: "Google Chrome") {
            [self.win(owner: "Google Chrome", title: "Meet – Weekly Sync")]
        }
        XCTAssertEqual(detector.checkOnce()?.pattern.appName, "Google Meet")
    }

    func testDetectsMeetTitleWithBrowserSuffix() {
        // The window title may carry a profile/browser suffix — the meeting
        // regex is anchored at the start only.
        let detector = meetDetector {
            [self.win(owner: "Brave Browser", title: "Meet – abc-defg-hij - Brave")]
        }
        XCTAssertNotNil(detector.checkOnce())
    }

    // MARK: - Assertion alone must not fire

    func testIgnoresWebRTCAssertionWithoutMeetWindow() {
        // Any WebRTC site (Discord web, Whereby, …) holds the same assertion —
        // without an in-call Meet tab title the browser must NOT be recorded.
        let detector = meetDetector {
            [self.win(owner: "Brave Browser", title: "Some Video Chat — Whereby")]
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testIgnoresWebRTCAssertionWithEmptyWindowList() {
        // No Screen Recording permission → no window titles → never fires.
        let detector = meetDetector { [] }
        XCTAssertNil(detector.checkOnce())
    }

    func testIgnoresMeetLandingPage() {
        // The Meet landing page tab ("Google Meet") is idle, not a call.
        let detector = meetDetector {
            [self.win(owner: "Brave Browser", title: "Google Meet")]
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testIgnoresNonWebRTCBrowserAssertion() {
        // A browser playing media (YouTube etc.) with a Meet tab open in the
        // background must not fire: the assertion keyword doesn't match.
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 4242,
                processName: "Brave Browser",
                assertName: "Playing audio",
                assertType: "PreventUserIdleSystemSleep",
            )
        }
        detector.windowListProvider = {
            [self.win(owner: "Brave Browser", title: "Meet – abc-defg-hij")]
        }
        XCTAssertNil(detector.checkOnce())
    }

    // MARK: - Strict title matching (no non-idle fallback for browsers)

    func testStrictMatcherNeverFallsBackToUnrelatedTabTitle() {
        let matcher = MeetingTitleMatcher(pattern: .meet)
        let title = matcher.selectWindowTitle(from: [
            win(owner: "Brave Browser", title: "GitHub - pasrom/meeting-transcriber"),
            win(owner: "Brave Browser", title: "Gmail"),
        ])
        XCTAssertNil(title, "a browser's unrelated tab titles must never pass as the meeting")
    }

    func testStrictMatcherPrefersMeetingTitleAmongTabs() {
        let matcher = MeetingTitleMatcher(pattern: .meet)
        let title = matcher.selectWindowTitle(from: [
            win(owner: "Brave Browser", title: "GitHub - pasrom/meeting-transcriber"),
            win(owner: "Brave Browser", title: "Meet – abc-defg-hij"),
        ])
        XCTAssertEqual(title, "Meet – abc-defg-hij")
    }

    func testNonStrictMatcherKeepsNonIdleFallback() {
        // Teams keeps the tier-2 fallback: an unrecognised-but-real title still
        // surfaces rather than being over-filtered.
        let matcher = MeetingTitleMatcher(pattern: .teams)
        let title = matcher.selectWindowTitle(from: [
            win(owner: "Microsoft Teams", title: "Some unrecognised window"),
        ])
        XCTAssertEqual(title, "Some unrecognised window")
    }

    // MARK: - isMeetingActive

    func testMeetStaysActiveWhileAssertionHeldEvenIfTabUnfocused() throws {
        // Mid-call the user switches to another tab: the Meet title disappears
        // from the window list but the WebRTC assertion persists — the meeting
        // must stay active (recording continues).
        let detector = meetDetector {
            [self.win(owner: "Brave Browser", title: "Meet – abc-defg-hij")]
        }
        let meeting = try XCTUnwrap(detector.checkOnce())

        detector.windowListProvider = {
            [self.win(owner: "Brave Browser", title: "GitHub - pull requests")]
        }
        XCTAssertTrue(detector.isMeetingActive(meeting))

        detector.assertionProvider = { [:] }
        XCTAssertFalse(detector.isMeetingActive(meeting))
    }

    // MARK: - Apps to Watch filtering

    func testMeetPatternDroppedWhenNotWatched() {
        let names = PowerAssertionDetector.patterns(watching: ["Zoom"]).map(\.appName)
        XCTAssertFalse(names.contains("Google Meet"))
    }

    func testMeetPatternKeptWhenWatched() {
        let names = PowerAssertionDetector.patterns(watching: ["Google Meet"]).map(\.appName)
        XCTAssertTrue(names.contains("Google Meet"))
    }
}
