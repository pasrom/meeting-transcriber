@testable import MeetingTranscriber
import XCTest

// MARK: - Test Helpers

/// Builds a single-app IOKit power-assertion dictionary in the shape
/// `PowerAssertionDetector.assertionProvider` yields. Internal (not private) so
/// PowerAssertionDetectorTitleTests can reuse it instead of re-declaring it.
func makeAssertionDict(
    pid: Int32,
    processName: String,
    assertName: String,
    assertType: String = "PreventUserIdleDisplaySleep",
) -> [Int32: [[String: Any]]] {
    [pid: [[
        "Process Name": processName,
        "AssertName": assertName,
        "AssertType": assertType,
        "AssertPID": pid,
        "AssertLevel": 255,
    ]]]
}

private func makeDetector(confirmationCount: Int = 1) -> PowerAssertionDetector {
    let detector = PowerAssertionDetector(confirmationCount: confirmationCount)
    detector.windowListProvider = { [] } // no real windows in unit tests
    return detector
}

// MARK: - Detection Tests

final class PowerAssertionDetectorTests: XCTestCase {
    func testNoAssertionsReturnsNil() {
        let detector = makeDetector()
        detector.assertionProvider = { [:] }
        XCTAssertNil(detector.checkOnce())
    }

    func testDetectsMSTeamsCall() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 1438,
                processName: "MSTeams",
                assertName: "Microsoft Teams Call in progress",
            )
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Microsoft Teams")
        XCTAssertEqual(result?.windowTitle, "Microsoft Teams Call in progress")
        XCTAssertEqual(result?.ownerName, "MSTeams")
        XCTAssertEqual(result?.windowPID, 1438)
    }

    func testDetectsTeamsLegacyProcessName() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 1234,
                processName: "MSTeams",
                assertName: "Microsoft Teams Call in progress",
            )
        }
        XCTAssertNotNil(detector.checkOnce())
    }

    func testDetectsTeamsWorkOrSchool() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 5678,
                processName: "Microsoft Teams (work or school)",
                assertName: "Microsoft Teams Call in progress",
            )
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Microsoft Teams")
    }

    func testIgnoresTeamsVideoWakeLock() {
        // "Video Wake Lock" persists even without a call — must NOT trigger detection
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 4211,
                processName: "Microsoft Teams WebView",
                assertName: "Video Wake Lock",
            )
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testDetectsZoomCall() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 2345,
                processName: "zoom.us",
                assertName: "Zoom Video Communication",
            )
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Zoom")
    }

    func testDetectsZoomPlaceholderAssertion() {
        // Field data (macOS 26, Zoom Workplace, issue #446): the in-call assertion
        // is a display-sleep assertion whose name is Apple's sample-code placeholder,
        // so the "zoom" keyword never appears. Detection must fall back to the
        // display-sleep assertion *type* for zoom.us.
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 65978,
                processName: "zoom.us",
                assertName: "Describe Activity Type",
                assertType: "NoDisplaySleepAssertion",
            )
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Zoom")
    }

    func testIgnoresZoomSystemSleepAssertion() {
        // Only display-sleep assertion types count as an active Zoom call. A
        // system-sleep assertion with the same placeholder name (e.g. during a
        // recording conversion or update) must NOT trigger detection.
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 65978,
                processName: "zoom.us",
                assertName: "Describe Activity Type",
                assertType: "PreventUserIdleSystemSleep",
            )
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testDetectsWebexCall() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 3456,
                processName: "Webex",
                assertName: "Webex Meeting Active",
            )
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Webex")
    }

    func testDetectsCiscoWebexCall() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 3457,
                processName: "Cisco Webex Meetings",
                assertName: "Webex active call",
            )
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Webex")
    }

    // MARK: - Ignore Non-Meeting Assertions

    func testIgnoresSafariAssertion() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 9999,
                processName: "Safari",
                assertName: "Playing video",
            )
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testIgnoresSpotifyAssertion() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 8888,
                processName: "Spotify",
                assertName: "Spotify is playing",
            )
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testIgnoresUnknownProcess() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 7777,
                processName: "SomeRandomApp",
                assertName: "call in progress",
            )
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testIgnoresTeamsWithoutKeyword() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 1234,
                processName: "MSTeams",
                assertName: "Downloading update",
            )
        }
        XCTAssertNil(detector.checkOnce())
    }

    // MARK: - Unmatched-App Diagnostics

    func testUnmatchedWatchedAssertionKeysReportsRunningUnmatchedApp() {
        // A watched meeting app is running but its assertion matches no pattern
        // this round — the diagnostic must surface it so a "stopped detecting"
        // report has a log line instead of needing manual pmset (issue #446).
        let assertions = makeAssertionDict(
            pid: 4211,
            processName: "MSTeams",
            assertName: "Downloading update",
            assertType: "PreventUserIdleSystemSleep",
        )
        let keys = PowerAssertionDetector.unmatchedWatchedAssertionKeys(
            assertions: assertions,
            patterns: PowerAssertionDetector.defaultPatterns,
            hits: [],
        )
        XCTAssertEqual(keys, ["MSTeams|Downloading update|PreventUserIdleSystemSleep"])
    }

    func testUnmatchedWatchedAssertionKeysSkipsMatchedAndUnwatched() {
        // Zoom matched this round (in hits) → not reported; Safari isn't a
        // watched meeting app → not reported.
        var assertions = makeAssertionDict(
            pid: 65978,
            processName: "zoom.us",
            assertName: "Describe Activity Type",
            assertType: "NoDisplaySleepAssertion",
        )
        assertions[9999] = [[
            "Process Name": "Safari",
            "AssertName": "Playing video",
            "AssertType": "PreventUserIdleDisplaySleep",
        ]]
        let keys = PowerAssertionDetector.unmatchedWatchedAssertionKeys(
            assertions: assertions,
            patterns: PowerAssertionDetector.defaultPatterns,
            hits: ["Zoom"],
        )
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: - Confirmation Threshold

    func testConfirmationThreshold() {
        let detector = makeDetector(confirmationCount: 3)
        let assertions = makeAssertionDict(
            pid: 1234,
            processName: "Microsoft Teams",
            assertName: "Microsoft Teams Call in progress",
        )
        detector.assertionProvider = { assertions }

        XCTAssertNil(detector.checkOnce()) // count=1
        XCTAssertNil(detector.checkOnce()) // count=2
        XCTAssertNotNil(detector.checkOnce()) // count=3
    }

    func testCounterResetsWhenAssertionDisappears() {
        let detector = makeDetector(confirmationCount: 3)
        let assertions = makeAssertionDict(
            pid: 1234,
            processName: "Microsoft Teams",
            assertName: "Microsoft Teams Call in progress",
        )

        detector.assertionProvider = { assertions }
        XCTAssertNil(detector.checkOnce()) // count=1

        // Assertion disappears
        detector.assertionProvider = { [:] }
        XCTAssertNil(detector.checkOnce()) // resets

        // Needs full count again
        detector.assertionProvider = { assertions }
        XCTAssertNil(detector.checkOnce()) // count=1
        XCTAssertNil(detector.checkOnce()) // count=2
        XCTAssertNotNil(detector.checkOnce()) // count=3
    }

    // MARK: - Cooldown

    func testCooldownPreventsRedetection() {
        let detector = makeDetector()
        let assertions = makeAssertionDict(
            pid: 1234,
            processName: "Microsoft Teams",
            assertName: "Microsoft Teams Call in progress",
        )
        detector.assertionProvider = { assertions }

        XCTAssertNotNil(detector.checkOnce())
        detector.reset(appName: "Microsoft Teams")
        XCTAssertNil(detector.checkOnce())
    }

    func testCooldownDoesNotAffectOtherApps() {
        let detector = makeDetector()

        // Detect Teams
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 1234,
                processName: "MSTeams",
                assertName: "Microsoft Teams Call in progress",
            )
        }
        XCTAssertNotNil(detector.checkOnce())
        detector.reset(appName: "Microsoft Teams")

        // Zoom should still work
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 2345,
                processName: "zoom.us",
                assertName: "Zoom Video Communication",
            )
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Zoom")
    }

    // MARK: - isMeetingActive

    func testIsMeetingActiveTrue() throws {
        let detector = makeDetector()
        let assertions = makeAssertionDict(
            pid: 1234,
            processName: "Microsoft Teams",
            assertName: "Microsoft Teams Call in progress",
        )
        detector.assertionProvider = { assertions }
        let meeting = try XCTUnwrap(detector.checkOnce())

        XCTAssertTrue(detector.isMeetingActive(meeting))
    }

    func testIsMeetingActiveDetectsZoomPlaceholder() throws {
        // End-of-meeting detection shares the matcher, so the placeholder
        // assertion must keep the Zoom meeting alive too.
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 65978,
                processName: "zoom.us",
                assertName: "Describe Activity Type",
                assertType: "NoDisplaySleepAssertion",
            )
        }
        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertTrue(detector.isMeetingActive(meeting))
    }

    func testIsMeetingActiveFalse() throws {
        let detector = makeDetector()
        let assertions = makeAssertionDict(
            pid: 1234,
            processName: "Microsoft Teams",
            assertName: "Microsoft Teams Call in progress",
        )
        detector.assertionProvider = { assertions }
        let meeting = try XCTUnwrap(detector.checkOnce())

        detector.assertionProvider = { [:] }
        XCTAssertFalse(detector.isMeetingActive(meeting))
    }

    // MARK: - Keyword Case Insensitivity

    func testKeywordMatchIsCaseInsensitive() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 1234,
                processName: "MSTeams",
                assertName: "MICROSOFT TEAMS CALL IN PROGRESS",
            )
        }
        XCTAssertNotNil(detector.checkOnce())
    }

    // MARK: - Window Title Lookup (further title cases in PowerAssertionDetectorTitleTests)

    func testAssertionNameUsedWhenNoWindowFound() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 1438,
                processName: "MSTeams",
                assertName: "Microsoft Teams Call in progress",
            )
        }
        // No matching windows
        detector.windowListProvider = { [] }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windowTitle, "Microsoft Teams Call in progress")
    }

    // MARK: - Reset Without App Name

    func testResetWithoutAppNameNoCooldown() {
        let detector = makeDetector()
        let assertions = makeAssertionDict(
            pid: 1234,
            processName: "Microsoft Teams",
            assertName: "Microsoft Teams Call in progress",
        )
        detector.assertionProvider = { assertions }

        XCTAssertNotNil(detector.checkOnce())
        detector.reset()
        XCTAssertNotNil(detector.checkOnce())
    }
}
