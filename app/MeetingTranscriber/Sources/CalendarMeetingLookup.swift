import EventKit
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "CalendarMeetingLookup")

/// Answers "which calendar event was this recording made in?" for `WatchLoop`.
/// Synchronous on purpose: it is consulted once, at enqueue time, and the
/// production implementation reads a local store. Permission is requested
/// from Settings when the feature is switched on, never from the poll loop.
protocol CalendarMeetingLookup {
    func meeting(startingAt start: Date, appName: String) -> CalendarMeeting?
}

/// The default: no calendar, window titles as before.
struct NoCalendarLookup: CalendarMeetingLookup {
    func meeting(startingAt _: Date, appName _: String) -> CalendarMeeting? {
        nil
    }
}

/// EventKit-backed lookup over every calendar the user has on the Mac. Reads
/// only: `EKEventStore` with full read access is the same store Calendar.app
/// shows, so a Google or Exchange account added in System Settings works
/// without a login of its own.
///
/// `isEnabled` is read on every call rather than captured once, so switching
/// the feature off in Settings takes effect for the next recording without
/// rebuilding the loop.
final class EventKitMeetingLookup: CalendarMeetingLookup {
    private let isEnabled: () -> Bool
    private let store = EKEventStore()

    /// The window scanned either side of the recording start. Wide enough for
    /// a long all-hands to still be running; the matcher trims it to events
    /// that actually cover the start.
    private static let scanWindow: TimeInterval = 4 * 3600

    init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
    }

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks macOS for full (read) access. Called from Settings when the toggle
    /// is switched on; the answer is also what the toggle's footnote reports.
    static func requestAccess() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToEvents()
        } catch {
            logger.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func meeting(startingAt start: Date, appName: String) -> CalendarMeeting? {
        guard isEnabled(), Self.hasAccess else { return nil }
        let predicate = store.predicateForEvents(
            withStart: start.addingTimeInterval(-Self.scanWindow),
            end: start.addingTimeInterval(Self.scanWindow),
            calendars: nil,
        )
        let candidates = store.events(matching: predicate).compactMap(Self.candidate)
        guard let match = CalendarMeetingMatcher.bestMatch(recordingStart: start, appName: appName, among: candidates) else {
            logger.info("No calendar event covers the recording start")
            return nil
        }
        logger.info(
            "Calendar event matched: \(match.meeting.title, privacy: .private)\(match.isAmbiguous ? " (another event shares the slot)" : "", privacy: .public)",
        )
        return match.meeting
    }

    /// Birthday and subscribed (holiday) calendars never describe a call, and
    /// a cancelled event is not a meeting anybody attended.
    private static func candidate(_ event: EKEvent) -> CalendarEventCandidate? {
        guard event.status != .canceled,
              event.calendar.type != .birthday, event.calendar.type != .subscription else { return nil }
        let attendees = (event.attendees ?? []).compactMap { attendee -> String? in
            guard attendee.participantType == .person, !attendee.isCurrentUser else { return nil }
            if let name = attendee.name, !name.isEmpty { return name }
            let address = attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return address.isEmpty ? nil : address
        }
        return CalendarEventCandidate(
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            attendees: attendees,
            conferenceText: [event.url?.absoluteString, event.location, event.notes].compactMap(\.self).joined(separator: " "),
        )
    }
}
