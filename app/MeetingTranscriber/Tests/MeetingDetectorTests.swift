// swiftlint:disable single_test_class
@testable import MeetingTranscriber
import XCTest

// MARK: - Test Helpers

private func makeWindow(
    owner: String,
    name: String,
    pid: Int32 = 1234,
    width: CGFloat = 800,
    height: CGFloat = 600,
) -> [String: Any] {
    [
        "kCGWindowOwnerName": owner,
        "kCGWindowName": name,
        "kCGWindowOwnerPID": pid,
        "kCGWindowBounds": ["Width": width, "Height": height],
    ]
}

private func makeDetector(
    patterns: [AppMeetingPattern],
    confirmationCount: Int = 1,
) -> MeetingDetector {
    MeetingDetector(patterns: patterns, confirmationCount: confirmationCount)
}

// MARK: - Pattern Tests

final class MeetingPatternsTests: XCTestCase {
    func testTeamsPatternHasRequiredFields() {
        XCTAssertEqual(AppMeetingPattern.teams.appName, "Microsoft Teams")
        XCTAssertFalse(AppMeetingPattern.teams.ownerNames.isEmpty)
        XCTAssertFalse(AppMeetingPattern.teams.meetingPatterns.isEmpty)
    }

    func testZoomPatternHasRequiredFields() {
        XCTAssertEqual(AppMeetingPattern.zoom.appName, "Zoom")
        XCTAssertFalse(AppMeetingPattern.zoom.ownerNames.isEmpty)
    }

    func testWebexPatternHasRequiredFields() {
        XCTAssertEqual(AppMeetingPattern.webex.appName, "Webex")
        XCTAssertFalse(AppMeetingPattern.webex.ownerNames.isEmpty)
    }

    func testAllPatternsContainsFour() {
        XCTAssertEqual(AppMeetingPattern.all.count, 4)
    }

    func testByNameLookup() {
        XCTAssertNotNil(AppMeetingPattern.byName["microsoft teams"])
        XCTAssertNotNil(AppMeetingPattern.byName["zoom"])
        XCTAssertNotNil(AppMeetingPattern.byName["webex"])
        XCTAssertNil(AppMeetingPattern.byName["slack"])
    }
}

// MARK: - Detector Tests

final class MeetingDetectorTests: XCTestCase {
    func testNoWindowsReturnsNil() {
        let detector = makeDetector(patterns: [.teams])
        detector.windowListProvider = { [] }
        XCTAssertNil(detector.checkOnce())
    }

    func testDetectsTeamsMeetingAfterConfirmation() {
        let detector = makeDetector(patterns: [.teams], confirmationCount: 2)
        let windows = [
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams"),
        ]
        detector.windowListProvider = { windows }

        // First check: not yet confirmed
        XCTAssertNil(detector.checkOnce())
        // Second check: confirmed
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Microsoft Teams")
        XCTAssertTrue(result?.windowTitle.contains("Sprint Review") ?? false)
    }

    func testDetectsTeamsMeetingWithConfirmation1() {
        let detector = makeDetector(patterns: [.teams])
        let windows = [
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams"),
        ]
        detector.windowListProvider = { windows }

        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windowPID, 1234)
    }

    func testIgnoresIdleTeamsWindow() {
        let detector = makeDetector(patterns: [.teams])
        detector.windowListProvider = {
            [makeWindow(owner: "Microsoft Teams", name: "Microsoft Teams")]
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testIgnoresChatWindow() {
        let detector = makeDetector(patterns: [.teams])
        detector.windowListProvider = {
            [makeWindow(owner: "Microsoft Teams", name: "Chat | John Doe")]
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testDetectsEchoTestCall() {
        let detector = makeDetector(patterns: [.teams])
        detector.windowListProvider = {
            [makeWindow(
                owner: "Microsoft Teams",
                name: "Echo | e.battery systems GmbH | user@company.com | Microsoft Teams",
            )]
        }
        // Echo test calls are allowed for testing purposes
        XCTAssertNotNil(detector.checkOnce())
    }

    func testIgnoresSmallWindows() {
        let detector = makeDetector(patterns: [.teams])
        detector.windowListProvider = {
            [makeWindow(
                owner: "Microsoft Teams",
                name: "Sprint Review | Microsoft Teams",
                width: 50, height: 50,
            )]
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testIgnoresEmptyTitle() {
        let detector = makeDetector(patterns: [.teams])
        detector.windowListProvider = {
            [makeWindow(owner: "Microsoft Teams", name: "")]
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testIgnoresWrongOwner() {
        let detector = makeDetector(patterns: [.teams])
        detector.windowListProvider = {
            [makeWindow(owner: "Firefox", name: "Sprint Review | Microsoft Teams")]
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testResetsCounterWhenWindowDisappears() {
        let detector = makeDetector(patterns: [.teams], confirmationCount: 3)
        let meetingWindows = [
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams"),
        ]

        // First hit
        detector.windowListProvider = { meetingWindows }
        XCTAssertNil(detector.checkOnce())

        // Window disappears — counter resets
        detector.windowListProvider = { [] }
        XCTAssertNil(detector.checkOnce())

        // Window reappears — needs full confirmationCount again
        detector.windowListProvider = { meetingWindows }
        XCTAssertNil(detector.checkOnce()) // count=1
        XCTAssertNil(detector.checkOnce()) // count=2
        XCTAssertNotNil(detector.checkOnce()) // count=3
    }

    func testDetectsZoomMeeting() {
        let detector = makeDetector(patterns: [.zoom])
        detector.windowListProvider = {
            [makeWindow(owner: "zoom.us", name: "Zoom Meeting")]
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Zoom")
    }

    func testDetectsZoomNamedMeeting() {
        let detector = makeDetector(patterns: [.zoom])
        detector.windowListProvider = {
            [makeWindow(owner: "zoom.us", name: "Sprint Planning - Zoom")]
        }
        XCTAssertNotNil(detector.checkOnce())
    }

    func testIgnoresZoomIdle() {
        let detector = makeDetector(patterns: [.zoom])
        detector.windowListProvider = {
            [makeWindow(owner: "zoom.us", name: "Zoom Workplace")]
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testDetectsWebexMeeting() {
        let detector = makeDetector(patterns: [.webex])
        detector.windowListProvider = {
            [makeWindow(owner: "Webex", name: "Team Sync - Webex")]
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Webex")
    }

    func testMultiplePatterns() {
        let detector = makeDetector(patterns: [.teams, .zoom])
        detector.windowListProvider = {
            [
                makeWindow(owner: "Microsoft Teams", name: "Microsoft Teams"), // idle
                makeWindow(owner: "zoom.us", name: "Zoom Meeting"), // active
            ]
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Zoom")
    }

    func testIsMeetingActiveTrue() throws {
        let detector = makeDetector(patterns: [.teams])
        let windows = [
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams"),
        ]
        detector.windowListProvider = { windows }
        let meeting = try XCTUnwrap(detector.checkOnce())

        XCTAssertTrue(detector.isMeetingActive(meeting))
    }

    func testIsMeetingActiveFalse() throws {
        let detector = makeDetector(patterns: [.teams])
        let windows = [
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams"),
        ]
        detector.windowListProvider = { windows }
        let meeting = try XCTUnwrap(detector.checkOnce())

        // Meeting window gone, only idle window
        detector.windowListProvider = {
            [makeWindow(owner: "Microsoft Teams", name: "Microsoft Teams")]
        }
        XCTAssertFalse(detector.isMeetingActive(meeting))
    }

    func testResetClearsCounters() {
        let detector = makeDetector(patterns: [.teams], confirmationCount: 2)
        let windows = [
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams"),
        ]
        detector.windowListProvider = { windows }
        XCTAssertNil(detector.checkOnce()) // count=1

        detector.reset()

        // After reset, needs full confirmation again
        XCTAssertNil(detector.checkOnce()) // count=1
    }

    func testCustomPattern() {
        let custom = AppMeetingPattern(
            appName: "Custom App",
            ownerNames: ["CustomApp"],
            meetingPatterns: [#"^Meeting:.*"#],
            idlePatterns: [#"^Custom App$"#],
        )
        let detector = makeDetector(patterns: [custom])
        detector.windowListProvider = {
            [makeWindow(owner: "CustomApp", name: "Meeting: Sprint")]
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Custom App")
    }

    func testTeamsWorkOrSchool() {
        let detector = makeDetector(patterns: [.teams])
        detector.windowListProvider = {
            [makeWindow(
                owner: "Microsoft Teams (work or school)",
                name: "Standup | Microsoft Teams",
            )]
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Microsoft Teams")
    }

    func testWebexPersonalRoom() {
        let detector = makeDetector(patterns: [.webex])
        detector.windowListProvider = {
            [makeWindow(owner: "Webex", name: "John's Personal Room")]
        }
        XCTAssertNotNil(detector.checkOnce())
    }

    func testZoomWebinar() {
        let detector = makeDetector(patterns: [.zoom])
        detector.windowListProvider = {
            [makeWindow(owner: "zoom.us", name: "Zoom Webinar")]
        }
        XCTAssertNotNil(detector.checkOnce())
    }

    // MARK: - Cooldown

    func testCooldownPreventsRedetection() {
        let detector = makeDetector(patterns: [.teams])
        let windows = [
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams"),
        ]
        detector.windowListProvider = { windows }

        // First detection
        let result = detector.checkOnce()
        XCTAssertNotNil(result)

        // Reset with cooldown
        detector.reset(appName: "Microsoft Teams")

        // Same window should NOT be detected during cooldown
        XCTAssertNil(detector.checkOnce())
    }

    func testCooldownDoesNotAffectOtherApps() {
        let detector = makeDetector(patterns: [.teams, .zoom])

        // First detect Teams
        detector.windowListProvider = {
            [makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams")]
        }
        XCTAssertNotNil(detector.checkOnce())

        // Put Teams on cooldown
        detector.reset(appName: "Microsoft Teams")

        // Zoom should still be detectable
        detector.windowListProvider = {
            [makeWindow(owner: "zoom.us", name: "Zoom Meeting")]
        }
        let result = detector.checkOnce()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.pattern.appName, "Zoom")
    }

    // MARK: - Coverage: Edge Cases

    func testDuplicateWindowsSameAppCountOnce() {
        // Two matching windows from same app should only count as one hit (line 79)
        let detector = makeDetector(patterns: [.teams], confirmationCount: 2)
        detector.windowListProvider = {
            [
                makeWindow(owner: "Microsoft Teams", name: "Meeting A | Microsoft Teams"),
                makeWindow(owner: "Microsoft Teams", name: "Meeting B | Microsoft Teams"),
            ]
        }

        // First poll: count=1 (not 2, because duplicate guard)
        XCTAssertNil(detector.checkOnce())
        // Second poll: count=2 → confirmed
        XCTAssertNotNil(detector.checkOnce())
    }

    func testWindowWithoutBoundsPassesSizeCheck() {
        // Window dict missing kCGWindowBounds — size check skipped (lines 146-148)
        let detector = makeDetector(patterns: [.teams])
        let window: [String: Any] = [
            "kCGWindowOwnerName": "Microsoft Teams",
            "kCGWindowName": "Sprint Review | Microsoft Teams",
            "kCGWindowOwnerPID": Int32(1234),
            // no kCGWindowBounds
        ]
        detector.windowListProvider = { [window] }
        XCTAssertNotNil(detector.checkOnce())
    }

    func testTitleNotMatchingAnyMeetingPattern() {
        // Title passes owner + idle checks but doesn't match meeting regex (lines 170-171)
        let detector = makeDetector(patterns: [.teams])
        detector.windowListProvider = {
            [makeWindow(owner: "Microsoft Teams", name: "Some Random Title")]
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testResetWithoutAppNameNoCooldown() {
        let detector = makeDetector(patterns: [.teams])
        let windows = [
            makeWindow(owner: "Microsoft Teams", name: "Sprint Review | Microsoft Teams"),
        ]
        detector.windowListProvider = { windows }

        // Detect and reset without cooldown
        XCTAssertNotNil(detector.checkOnce())
        detector.reset()

        // Should be detectable again immediately (no cooldown)
        XCTAssertNotNil(detector.checkOnce())
    }
}
