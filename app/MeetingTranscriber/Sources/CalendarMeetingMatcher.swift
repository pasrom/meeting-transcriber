import Foundation

/// A calendar event reduced to what matching needs, so the matcher can be
/// exercised without EventKit and the EventKit adapter stays a thin mapping.
struct CalendarEventCandidate: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// Display names (or addresses) of the other attendees; empty for a
    /// personal block with nobody invited.
    let attendees: [String]
    /// URL, location and notes joined together: where a conference link lives.
    let conferenceText: String
}

/// What the pipeline learns from a calendar match: the title the recording is
/// filed under and the attendees the protocol can name.
struct CalendarMeeting: Equatable, Sendable {
    let title: String
    let attendees: [String]
}

/// Pure choice of the calendar event a recording belongs to.
///
/// The event must still be running when the recording starts (an early join
/// is allowed up to `earlyJoin`), because the one failure worth designing
/// around is a call in the free slot after a meeting inheriting that
/// meeting's name. Among overlapping events, a conference link pointing at
/// the app in use wins, then events with attendees over personal blocks, then
/// the closest start.
enum CalendarMeetingMatcher {
    /// How long before an event's start a recording may begin and still count.
    static let earlyJoin: TimeInterval = 15 * 60

    struct Match: Equatable {
        let meeting: CalendarMeeting
        /// Another event scored the same, so the choice was arbitrary. Logged,
        /// not surfaced: the usual cause is one meeting present twice (an
        /// external invite plus one's own copy), where either title is right.
        let isAmbiguous: Bool
    }

    /// Conference domains a native meeting app implies. A browser implies
    /// nothing in particular, so any conference link counts for it.
    static func conferenceDomains(forApp appName: String) -> [String] {
        let name = appName.lowercased()
        if name.contains("zoom") { return ["zoom.us"] }
        if name.contains("teams") { return ["teams.microsoft.com", "teams.live.com"] }
        if name.contains("webex") { return ["webex.com"] }
        if name.contains("facetime") { return ["facetime.apple.com"] }
        return ["zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "meet.google.com", "whereby.com", "telemost.yandex"]
    }

    static func bestMatch(recordingStart: Date, appName: String, among events: [CalendarEventCandidate]) -> Match? {
        let domains = conferenceDomains(forApp: appName)
        let scored: [(CalendarEventCandidate, Int)] = events.compactMap { event in
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !event.isAllDay, !title.isEmpty else { return nil }
            guard event.start <= recordingStart.addingTimeInterval(earlyJoin),
                  event.end >= recordingStart else { return nil }
            var score = 0
            let text = event.conferenceText.lowercased()
            if domains.contains(where: { text.contains($0) }) { score += 100 }
            if !event.attendees.isEmpty { score += 10 }
            score -= Int(abs(event.start.timeIntervalSince(recordingStart)) / 60)
            return (event, score)
        }
        guard let top = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        let meeting = CalendarMeeting(
            title: top.0.title.trimmingCharacters(in: .whitespacesAndNewlines),
            attendees: top.0.attendees,
        )
        return Match(meeting: meeting, isAmbiguous: scored.filter { $0.1 == top.1 }.count > 1)
    }
}
