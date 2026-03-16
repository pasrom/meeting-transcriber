@testable import MeetingTranscriber
import XCTest

// MARK: - Test Helpers

private func makeAssertionDict(
    pid: Int32,
    processName: String,
    assertName: String,
    assertType: String = "PreventUserIdleDisplaySleep",
) -> [Int32: [[String: Any]]] {
    [
        pid: [
            [
                "Process Name": processName,
                "AssertName": assertName,
                "AssertType": assertType,
                "AssertPID": pid,
                "AssertLevel": 255,
            ],
        ],
    ]
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

    // MARK: - Reset Without App Name

    // MARK: - Window Title Lookup

    func testWindowTitleUsedWhenFound() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 1438,
                processName: "MSTeams",
                assertName: "Microsoft Teams Call in progress",
            )
        }
        detector.windowListProvider = {
            [[
                "kCGWindowOwnerName": "Microsoft Teams",
                "kCGWindowName": "Sprint Review | Microsoft Teams",
                "kCGWindowOwnerPID": Int32(1438),
            ]]
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windowTitle, "Sprint Review | Microsoft Teams")
    }

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

    func testWindowTitleSkipsEmptyAndAppNameOnly() {
        let detector = makeDetector()
        detector.assertionProvider = {
            makeAssertionDict(
                pid: 1438,
                processName: "MSTeams",
                assertName: "Microsoft Teams Call in progress",
            )
        }
        detector.windowListProvider = {
            [
                // Empty title — should be skipped
                [
                    "kCGWindowOwnerName": "Microsoft Teams",
                    "kCGWindowName": "",
                    "kCGWindowOwnerPID": Int32(1438),
                ],
                // Title equals app name — should be skipped
                [
                    "kCGWindowOwnerName": "Microsoft Teams",
                    "kCGWindowName": "Microsoft Teams",
                    "kCGWindowOwnerPID": Int32(1438),
                ],
                // Real meeting title
                [
                    "kCGWindowOwnerName": "Microsoft Teams",
                    "kCGWindowName": "Daily Standup | Microsoft Teams",
                    "kCGWindowOwnerPID": Int32(1438),
                ],
            ]
        }
        let result = detector.checkOnce()
        XCTAssertEqual(result?.windowTitle, "Daily Standup | Microsoft Teams")
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
