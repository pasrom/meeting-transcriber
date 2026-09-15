import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoopCalendarTitle")

/// Calendar-backed naming, split out of `WatchLoop` the way consent and manual
/// recording are: `enqueueRecording` stays the single funnel every trigger
/// (auto, manual, microphone-only, record-only sidecar) passes through, and
/// this is the one place that funnel consults the calendar.
extension WatchLoop {
    /// The title and participants a recording is filed under once the
    /// calendar has had its say. Consulted at enqueue rather than at
    /// detection so all triggers are named by the same rule, against the
    /// start the recorder actually captured; `.distantPast` is the recorder's
    /// "unknown" sentinel, and the clock is the next best anchor.
    ///
    /// `calendarMayName` is false for a title the user typed: that is a
    /// decision, not a fallback. Participants the app read from the call
    /// (Teams) are what was actually said, so the invite list only fills in
    /// when there is nothing.
    func calendarNamed(
        title: String,
        participants: [String],
        appName: String,
        recording: RecordingResult,
        calendarMayName: Bool,
    ) -> (title: String, participants: [String]) {
        guard calendarMayName else { return (title, participants) }
        let start = recording.recordingStartDate == .distantPast ? nowProvider() : recording.recordingStartDate
        guard let meeting = calendarLookup.meeting(startingAt: start, appName: appName) else {
            return (title, participants)
        }
        logger.info("Recording named after calendar event: \(meeting.title, privacy: .private)")
        return (meeting.title, participants.isEmpty ? meeting.attendees : participants)
    }
}
