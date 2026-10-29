import CoreGraphics
import Foundation

/// Represents a detected active meeting.
struct DetectedMeeting: Equatable {
    let pattern: AppMeetingPattern
    let windowTitle: String
    let ownerName: String
    let windowPID: pid_t
    let detectedAt: Date

    init(
        pattern: AppMeetingPattern,
        windowTitle: String,
        ownerName: String,
        windowPID: pid_t,
        detectedAt: Date = Date(),
    ) {
        self.pattern = pattern
        self.windowTitle = windowTitle
        self.ownerName = ownerName
        self.windowPID = windowPID
        self.detectedAt = detectedAt
    }
}

/// What a detector knows about which call a meeting app is in.
enum ActiveCalls: Equatable {
    /// The detector cannot tell one call of an app from the next.
    case unidentified
    /// IDs of the calls active right now; empty when the app is in none.
    case ids(Set<String>)
}

/// Protocol for meeting detection strategies.
protocol MeetingDetecting {
    /// Single poll: check for active meetings. Returns a meeting after confirmation threshold.
    func checkOnce() -> DetectedMeeting?

    /// Check if a previously detected meeting is still active.
    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool

    /// The calls currently keeping `meeting` active, so the watch loop can
    /// end a recording when the app moves on to another call (issue #765).
    func activeCalls(_ meeting: DetectedMeeting) -> ActiveCalls

    /// Reset confirmation counters and start cooldown for the given app.
    func reset(appName: String?)
}

extension MeetingDetecting {
    func activeCalls(_: DetectedMeeting) -> ActiveCalls {
        .unidentified
    }

    func reset() {
        reset(appName: nil)
    }
}
