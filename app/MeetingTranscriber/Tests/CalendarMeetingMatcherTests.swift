@testable import MeetingTranscriber
import XCTest

/// Pure matching of a recording start against calendar events. The rule that
/// matters most is the last one: a call that starts in the free slot after a
/// meeting must not inherit that meeting's name.
final class CalendarMeetingMatcherTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Int) -> Date {
        base.addingTimeInterval(TimeInterval(minutes * 60))
    }

    private func event(
        _ title: String, from: Int, to: Int, attendees: [String] = ["Someone"],
        text: String = "", allDay: Bool = false,
    ) -> CalendarEventCandidate {
        CalendarEventCandidate(
            title: title, start: at(from), end: at(to), isAllDay: allDay,
            attendees: attendees, conferenceText: text,
        )
    }

    func testPicksTheEventRunningAtRecordingStart() throws {
        let weekly = event("Weekly", from: 0, to: 60)
        let later = event("Later", from: 120, to: 150)
        let match = try XCTUnwrap(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(40), appName: "Zoom", among: [later, weekly],
        ))
        XCTAssertEqual(match.meeting.title, "Weekly")
        XCTAssertEqual(match.meeting.attendees, ["Someone"])
        XCTAssertFalse(match.isAmbiguous)
    }

    func testNothingRunningMeansNoMatch() {
        XCTAssertNil(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(90), appName: "Zoom", among: [event("Weekly", from: 0, to: 60)],
        ))
    }

    func testJoiningEarlyStillMatches() {
        let match = CalendarMeetingMatcher.bestMatch(
            recordingStart: at(-10), appName: "Zoom", among: [event("Weekly", from: 0, to: 60)],
        )
        XCTAssertEqual(match?.meeting.title, "Weekly")
    }

    func testJoiningTooEarlyDoesNotMatch() {
        XCTAssertNil(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(-30), appName: "Zoom", among: [event("Weekly", from: 0, to: 60)],
        ))
    }

    /// The failure this rule exists for: an unscheduled call at 13:10 after a
    /// 12:00–13:00 weekly was being filed under the weekly.
    func testRecordingThatStartsAfterTheEventEndedIsNotThatEvent() {
        XCTAssertNil(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(70), appName: "Arc", among: [event("Weekly", from: 0, to: 60)],
        ))
    }

    func testAllDayEventsNeverMatch() {
        XCTAssertNil(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(40), appName: "Zoom",
            among: [event("Public holiday", from: -600, to: 840, attendees: [], allDay: true)],
        ))
    }

    /// Two events in the same slot (an external invite plus one's own copy is
    /// the usual cause): the one whose link points at the app in use wins.
    func testConferenceLinkMatchingTheAppBreaksATie() throws {
        let plain = event("EXT: partner sync", from: 0, to: 60)
        let linked = event("Partner sync", from: 0, to: 60, text: "https://zoom.us/j/123")
        let match = try XCTUnwrap(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(2), appName: "Zoom", among: [plain, linked],
        ))
        XCTAssertEqual(match.meeting.title, "Partner sync")
        XCTAssertFalse(match.isAmbiguous)
    }

    /// A browser carries no service of its own, so any conference link counts.
    func testBrowserAcceptsAnyConferenceLink() throws {
        let plain = event("EXT: partner sync", from: 0, to: 60)
        let linked = event("Partner sync", from: 0, to: 60, text: "join: https://meet.google.com/abc-defg")
        let match = try XCTUnwrap(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(2), appName: "Arc", among: [plain, linked],
        ))
        XCTAssertEqual(match.meeting.title, "Partner sync")
    }

    func testIdenticalCandidatesAreReportedAsAmbiguous() throws {
        let one = event("Sync", from: 0, to: 60)
        let two = event("Sync (copy)", from: 0, to: 60)
        let match = try XCTUnwrap(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(2), appName: "Zoom", among: [one, two],
        ))
        XCTAssertTrue(match.isAmbiguous)
    }

    func testEventWithAttendeesBeatsAPersonalBlockInTheSameSlot() throws {
        let block = event("Focus time", from: 0, to: 120, attendees: [])
        let call = event("1-2-1", from: 30, to: 60)
        let match = try XCTUnwrap(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(31), appName: "Zoom", among: [block, call],
        ))
        XCTAssertEqual(match.meeting.title, "1-2-1")
    }

    func testClosestStartWinsAmongOverlappingEvents() throws {
        let long = event("All-hands", from: 0, to: 180)
        let nested = event("Breakout", from: 60, to: 90)
        let match = try XCTUnwrap(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(61), appName: "Zoom", among: [long, nested],
        ))
        XCTAssertEqual(match.meeting.title, "Breakout")
    }

    func testBlankTitlesAreSkipped() {
        XCTAssertNil(CalendarMeetingMatcher.bestMatch(
            recordingStart: at(10), appName: "Zoom", among: [event("   ", from: 0, to: 60)],
        ))
    }
}
