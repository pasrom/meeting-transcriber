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
            makeAssertionDict(pid: 1438, processName: "MSTeams", assertName: "Microsoft Teams Call in progress")
        }
        detector.windowListProvider = windows
        return detector
    }

    private func zoomDetector(windows: @escaping () -> [[String: Any]]) -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(confirmationCount: 1)
        detector.assertionProvider = {
            makeAssertionDict(pid: 2020, processName: "zoom.us", assertName: "Zoom Video Communication")
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

    func testOneToOneCallUsesTheCallerWindowTitle() {
        // A 1:1 Teams call window is titled with the other person's name; that
        // becomes the meeting title. The " | Microsoft Teams" suffix is stripped
        // downstream by WatchLoop.cleanTitle (covered in WatchLoopTests) → "Jane Doe".
        let detector = teamsDetector { [self.win(owner: "Microsoft Teams", title: "Jane Doe | Microsoft Teams")] }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Jane Doe | Microsoft Teams")
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

    // MARK: - Pattern-table drift guard

    func testEveryWatchedAssertionAppHasAMeetingPattern() {
        // The title matcher is built by joining the assertion-pattern table to
        // the meeting-pattern table on appName. If an app is added to one but
        // not the other, its titles silently become the placeholder forever —
        // this pins the two tables together so the drift fails here, not in the field.
        for pattern in PowerAssertionDetector.defaultPatterns {
            XCTAssertNotNil(
                AppMeetingPattern.forAppName(pattern.appName),
                "\(pattern.appName) has no AppMeetingPattern; its meeting titles would always be the placeholder",
            )
        }
    }

    func testWatchedAppWithoutMeetingPatternFallsBackToPlaceholder() {
        // The drift the consistency test guards against, exercised: a watched
        // assertion app with no matching AppMeetingPattern gets no title matcher
        // (init logs + skips it), so its window title can't be looked up and the
        // detector substitutes the "<app> Call" placeholder rather than leaking a
        // window/assertion string. Also covers the synthesized-pattern fallback.
        let detector = PowerAssertionDetector(
            patterns: [.init(appName: "Unknown App", processNames: ["unknownproc"], keywords: ["unknownmeeting"])],
            confirmationCount: 1,
        )
        detector.assertionProvider = {
            makeAssertionDict(pid: 999, processName: "unknownproc", assertName: "unknownmeeting in progress")
        }
        detector.windowListProvider = { [self.win(owner: "unknownproc", title: "Some Window", pid: 999)] }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Unknown App Call")
    }
}
