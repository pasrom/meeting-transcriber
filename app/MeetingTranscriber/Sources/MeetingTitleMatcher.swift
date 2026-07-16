import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingTitleMatcher")

/// Compiled idle/meeting title semantics for one `AppMeetingPattern`.
///
/// Both meeting detectors classify window titles the same way — an idle-tab
/// title (Teams' Calendar/Chat/… tabs) is not a meeting, a title matching the
/// app's meeting patterns is. `MeetingDetector` used to own this logic;
/// `PowerAssertionDetector` re-implemented a weaker version that skipped the
/// idle check entirely (letting the Calendar tab leak in as the meeting title).
/// Sharing the compiled matcher keeps the two in lock-step. Regexes are
/// compiled once; invalid patterns are logged and dropped.
struct MeetingTitleMatcher {
    let appName: String
    let ownerNames: [String]
    private let idleRegexes: [NSRegularExpression]
    private let meetingRegexes: [NSRegularExpression]

    init(pattern: AppMeetingPattern) {
        appName = pattern.appName
        ownerNames = pattern.ownerNames
        idleRegexes = Self.compile(pattern.idlePatterns, kind: "idle", appName: pattern.appName)
        meetingRegexes = Self.compile(pattern.meetingPatterns, kind: "meeting", appName: pattern.appName)
    }

    /// True when `title` matches one of the app's idle-tab patterns (e.g. Teams'
    /// `Calendar | …`). Must be checked *before* `isMeetingTitle`: a Calendar-tab
    /// title also matches the Teams meeting regex, so meeting classification
    /// alone would misclassify it as a real meeting.
    func isIdleTitle(_ title: String) -> Bool {
        Self.anyMatch(idleRegexes, title)
    }

    /// True when `title` matches one of the app's meeting-window patterns.
    func isMeetingTitle(_ title: String) -> Bool {
        Self.anyMatch(meetingRegexes, title)
    }

    private static func anyMatch(_ regexes: [NSRegularExpression], _ title: String) -> Bool {
        let range = NSRange(title.startIndex..., in: title)
        return regexes.contains { $0.firstMatch(in: title, range: range) != nil }
    }

    private static func compile(_ patterns: [String], kind: String, appName: String) -> [NSRegularExpression] {
        patterns.compactMap { pattern in
            do {
                return try NSRegularExpression(pattern: pattern)
            } catch {
                logger.error(
                    "Invalid \(kind, privacy: .public) regex for \(appName, privacy: .public): \(pattern, privacy: .public) — \(error.localizedDescription, privacy: .public)",
                )
                return nil
            }
        }
    }
}
