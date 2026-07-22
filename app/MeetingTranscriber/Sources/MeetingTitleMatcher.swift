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
    /// Mirrors `AppMeetingPattern.strictTitleMatch`: when set, only
    /// meeting-pattern titles are usable — `selectWindowTitle` never falls back
    /// to the first non-idle title (a browser's unrelated tabs would leak in).
    let strictTitleMatch: Bool
    private let idleRegexes: [NSRegularExpression]
    private let meetingRegexes: [NSRegularExpression]

    init(pattern: AppMeetingPattern) {
        appName = pattern.appName
        ownerNames = pattern.ownerNames
        strictTitleMatch = pattern.strictTitleMatch
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

    /// Pick the best usable window title for this app from a `CGWindowList`
    /// snapshot. Skips windows whose owner isn't ours, and titles that are
    /// empty, equal to the app name, or idle-tab titles. Then, tiered:
    /// 1. the first surviving title that matches a meeting pattern (the call
    ///    window — for a 1:1 Teams call that is the other person's name);
    /// 2. else the first surviving (non-idle) title, so an unrecognised-but-real
    ///    title still surfaces rather than being over-filtered;
    /// 3. else `nil` — the caller substitutes a clean placeholder.
    /// No minimum-size gate here: a snapshot missing `kCGWindowBounds` must not
    /// degrade a real title to the placeholder (title source only).
    /// Idle-skip takes priority over the meeting match by design: never leaking
    /// a Teams tab title is the goal, so a real meeting whose subject happens to
    /// equal a tab name (e.g. a call literally titled "Files") degrades to the
    /// placeholder. The opposite priority would re-leak the Calendar tab. This
    /// matches `MeetingDetector`'s long-standing idle-before-meeting order.
    func selectWindowTitle(from windows: [[String: Any]]) -> String? {
        var firstNonIdle: String?
        for window in windows {
            guard let owner = window["kCGWindowOwnerName"] as? String,
                  ownerNames.contains(owner),
                  let title = window["kCGWindowName"] as? String,
                  !title.isEmpty,
                  title != appName,
                  !isIdleTitle(title) else {
                continue
            }
            if isMeetingTitle(title) { return title }
            if firstNonIdle == nil, !strictTitleMatch { firstNonIdle = title }
        }
        return firstNonIdle
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
