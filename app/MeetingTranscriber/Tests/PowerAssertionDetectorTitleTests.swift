@testable import MeetingTranscriber
import XCTest

/// Title-selection behaviour of `PowerAssertionDetector`: it must prefer the
/// real meeting window's title, skip Teams' idle-tab titles, and (once the
/// placeholder ships) never leak the raw assertion name. Split out of
/// `PowerAssertionDetectorTests` (that file is at the `type_body_length` cap).
final class PowerAssertionDetectorTitleTests: XCTestCase {
    private func win(owner: String, title: String?, pid: Int32 = 1438) -> [String: Any] {
        var w: [String: Any] = ["kCGWindowOwnerName": owner, "kCGWindowOwnerPID": pid]
        if let title { w["kCGWindowName"] = title }
        return w
    }

    private func teamsDetector(windows: @escaping () -> [[String: Any]]) -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.assertionProvider = {
            [1438: [[
                "Process Name": "MSTeams",
                "AssertName": "Microsoft Teams Call in progress",
                "AssertType": "PreventUserIdleDisplaySleep",
                "AssertPID": Int32(1438),
                "AssertLevel": 255,
            ]]]
        }
        detector.windowListProvider = windows
        return detector
    }

    private func zoomDetector(windows: @escaping () -> [[String: Any]]) -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.assertionProvider = {
            [2020: [[
                "Process Name": "zoom.us",
                "AssertName": "Zoom Video Communication",
                "AssertType": "PreventUserIdleDisplaySleep",
                "AssertPID": Int32(2020),
                "AssertLevel": 255,
            ]]]
        }
        detector.windowListProvider = windows
        return detector
    }

    // MARK: - Moved from PowerAssertionDetectorTests (Window Title Lookup)

    func testWindowTitleUsedWhenFound() {
        let detector = teamsDetector { [self.win(owner: "Microsoft Teams", title: "Sprint Review | Microsoft Teams")] }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Sprint Review | Microsoft Teams")
    }

    func testWindowTitleSkipsEmptyAndAppNameOnly() {
        let detector = teamsDetector {
            [
                self.win(owner: "Microsoft Teams", title: ""),
                self.win(owner: "Microsoft Teams", title: "Microsoft Teams"),
                self.win(owner: "Microsoft Teams", title: "Daily Standup | Microsoft Teams"),
            ]
        }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Daily Standup | Microsoft Teams")
    }

    // MARK: - Idle-skip + meeting-pattern preference (this commit)

    func testSkipsIdleCalendarPrefersMeetingWindow() {
        // The Calendar-tab window is first AND matches the Teams meeting regex —
        // the exact case the old code got wrong (it returned the first match).
        let detector = teamsDetector {
            [
                self.win(owner: "Microsoft Teams", title: "Calendar | Contoso | user@contoso.com | Microsoft Teams"),
                self.win(owner: "Microsoft Teams", title: "Sprint Review | Microsoft Teams"),
            ]
        }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Sprint Review | Microsoft Teams")
    }

    @MainActor
    func testOneToOneCallTitleCleansToCallerName() {
        let detector = teamsDetector { [self.win(owner: "Microsoft Teams", title: "Jane Doe | Microsoft Teams")] }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Jane Doe | Microsoft Teams")
        // The suffix is stripped downstream in WatchLoop → filename "Jane Doe".
        XCTAssertEqual(WatchLoop.cleanTitle("Jane Doe | Microsoft Teams"), "Jane Doe")
    }

    func testZoomMeetingWindowUsed() {
        // Zoom's in-call window is literally titled "Zoom Meeting" (a meeting
        // pattern) — it must get the real title, not a placeholder.
        let detector = zoomDetector { [self.win(owner: "zoom.us", title: "Zoom Meeting")] }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Zoom Meeting")
    }

    func testNonIdleNonMeetingTitleKeptAsTier2() {
        // Neither idle nor a meeting-pattern match: preserve today's behaviour
        // (surface it) rather than over-filter to a placeholder.
        let detector = teamsDetector { [self.win(owner: "Microsoft Teams", title: "Some Popup")] }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Some Popup")
    }

    func testFirstMeetingWindowWinsInProviderOrder() {
        let detector = teamsDetector {
            [
                self.win(owner: "Microsoft Teams", title: "A | Microsoft Teams"),
                self.win(owner: "Microsoft Teams", title: "B | Microsoft Teams"),
            ]
        }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "A | Microsoft Teams")
    }

    // MARK: - Placeholder fallback (this commit)

    func testIdleOnlyWindowsFallBackToPlaceholder() {
        // Only the Calendar tab is open (idle) — no real meeting window. The
        // title must not be the Calendar tab nor the raw assertion name.
        let detector = teamsDetector {
            [self.win(owner: "Microsoft Teams", title: "Calendar | Contoso | user@contoso.com | Microsoft Teams")]
        }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Microsoft Teams Call")
    }

    func testEmptyWindowListFallsBackToPlaceholder() {
        // Replaces the old assertion-name fallback: no windows (e.g. Screen
        // Recording denied) must yield a clean placeholder, not the assertName.
        let detector = teamsDetector { [] }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Microsoft Teams Call")
    }

    func testMissingWindowNameFallsBackToPlaceholder() {
        // Field case: Screen Recording denied → kCGWindowName absent; the raw
        // Zoom assertion name ("Describe Activity Type" in the wild) must not leak.
        let detector = zoomDetector { [self.win(owner: "zoom.us", title: nil)] }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Zoom Call")
    }
}
