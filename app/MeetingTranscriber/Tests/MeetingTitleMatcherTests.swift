@testable import MeetingTranscriber
import XCTest

final class MeetingTitleMatcherTests: XCTestCase {
    private let teams = MeetingTitleMatcher(pattern: .teams)

    func test_isIdleTitle_matchesTeamsIdleTabs() {
        XCTAssertTrue(teams.isIdleTitle("Calendar | Contoso | user@contoso.com | Microsoft Teams"))
        XCTAssertTrue(teams.isIdleTitle("Microsoft Teams"))
        XCTAssertTrue(teams.isIdleTitle("Chat | Contoso"))
        XCTAssertFalse(teams.isIdleTitle("Sprint Review | Microsoft Teams"))
        XCTAssertFalse(teams.isIdleTitle("Jane Doe | Microsoft Teams"))
    }

    func test_isMeetingTitle_matchesRealMeetingWindows() {
        XCTAssertTrue(teams.isMeetingTitle("Sprint Review | Microsoft Teams"))
        // The Calendar-tab title ALSO matches the meeting regex — this is exactly
        // why idle titles must be excluded *before* meeting classification.
        XCTAssertTrue(teams.isMeetingTitle("Calendar | Contoso | Microsoft Teams"))
        XCTAssertTrue(MeetingTitleMatcher(pattern: .zoom).isMeetingTitle("Zoom Meeting"))
        XCTAssertFalse(teams.isMeetingTitle("Home"))
        XCTAssertFalse(teams.isMeetingTitle(""))
    }

    func test_invalidRegexIsDroppedNotCrashed() {
        let bad = AppMeetingPattern(
            appName: "X", ownerNames: ["X"],
            meetingPatterns: ["[unterminated"], idlePatterns: ["(also bad"],
        )
        let matcher = MeetingTitleMatcher(pattern: bad)
        XCTAssertFalse(matcher.isMeetingTitle("anything"))
        XCTAssertFalse(matcher.isIdleTitle("anything"))
    }
}
