@testable import MeetingTranscriber
import XCTest

/// Wording of the launch-time notice for a run that ended without a quit
/// (issue #703). Pinned in a fixed locale, calendar and time zone so the
/// assertions do not depend on the machine running them.
final class PreviousExitNoticeTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let locale = Locale(identifier: "en_GB")
    // swiftlint:disable:next force_unwrapping
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso), "bad fixture date \(iso)")
    }

    private func notice(lastAlive: String, now: String) throws -> PreviousExitNotice {
        try PreviousExitNotice(
            lastAlive: date(lastAlive), now: date(now),
            calendar: calendar, locale: locale, timeZone: utc,
        )
    }

    /// The reporter's case: a morning crash noticed and relaunched hours
    /// later, on the same day. The notice names both ends of the window and
    /// says what the window meant.
    func testASameDayWindowIsNamedByItsTimes() throws {
        let notice = try notice(lastAlive: "2026-09-09T10:52:00Z", now: "2026-09-09T14:03:00Z")

        XCTAssertEqual(
            notice.body,
            "It stopped without quitting at about 10:52 and was not watching for meetings "
                + "until 14:03. Nothing was recorded in between.",
        )
    }

    /// A window that crosses midnight would read as this morning if the stop
    /// carried only a time, so the date is added, after the time: "at about
    /// 10:52 on 8 Mar". Pinned in full because this is the common case (a
    /// crash in the evening, noticed the next morning) and a `contains` check
    /// let "at about 8 Mar at 10:52" through.
    func testAWindowFromAnEarlierDayCarriesTheDate() throws {
        let notice = try notice(lastAlive: "2026-03-08T10:52:00Z", now: "2026-03-09T14:03:00Z")

        XCTAssertEqual(
            notice.body,
            "It stopped without quitting at about 10:52 on 8 Mar and was not watching for meetings "
                + "until 14:03. Nothing was recorded in between.",
        )
    }

    /// The title is what the user could not see for themselves.
    func testTheTitleSaysTheAppWasNotRunning() {
        XCTAssertEqual(PreviousExitNotice.title, "Meeting Transcriber was not running")
    }
}
