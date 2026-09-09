import Foundation

/// The launch-time message for a previous run that ended without a quit
/// (issue #703). Pure text so the wording, and the window it names, can be
/// pinned without a notification centre.
///
/// It names the window and says what the window meant. "Was not running" is
/// the part the user could not see: a menu bar app that is gone looks exactly
/// like one that is idle, and the whole point of the app is that it records
/// without being watched. It does not say "crashed", because a Force Quit or
/// a power cut leave the same trace and the user may know better.
struct PreviousExitNotice: Equatable {
    static let title = "Meeting Transcriber was not running"

    let body: String

    /// `lastAlive` is the previous run's last heartbeat and `now` this launch.
    /// The calendar, locale and time zone are injectable so a test can pin the
    /// wording without depending on the machine it runs on.
    init(
        lastAlive: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
    ) {
        var calendar = calendar
        calendar.timeZone = timeZone
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
        let dayAndMonth = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
            .day().month(.abbreviated)
        // The date is added only when it is not today's, which is when the
        // time alone would read as this morning. After the time, on its own,
        // because a combined style renders "8 Mar at 10:52" and the sentence
        // already says "at about".
        let stopped = calendar.isDate(lastAlive, inSameDayAs: now)
            ? lastAlive.formatted(time)
            : "\(lastAlive.formatted(time)) on \(lastAlive.formatted(dayAndMonth))"
        body = "It stopped without quitting at about \(stopped) and was not watching for meetings "
            + "until \(now.formatted(time)). Nothing was recorded in between."
    }
}
