import ApplicationServices
import CoreGraphics
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingDetector")

/// Represents a detected active meeting.
struct DetectedMeeting {
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
        detectedAt: Date = Date()
    ) {
        self.pattern = pattern
        self.windowTitle = windowTitle
        self.ownerName = ownerName
        self.windowPID = windowPID
        self.detectedAt = detectedAt
    }
}

/// Polls window list to detect active meeting windows.
///
/// Uses CGWindowListCopyWindowInfo to read on-screen windows.
/// Requires Screen Recording permission.
@Observable
class MeetingDetector {
    private let patterns: [AppMeetingPattern]
    private let confirmationCount: Int
    private var consecutiveHits: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private let cooldownDuration: TimeInterval = 5  // brief cooldown to avoid re-detecting the same meeting

    /// Pre-compiled regex for each pattern to avoid re-compilation on every poll.
    private let compiledMeetingPatterns: [String: [NSRegularExpression]]
    private let compiledIdlePatterns: [String: [NSRegularExpression]]

    /// Closure that provides the window list. Defaults to CGWindowListCopyWindowInfo.
    /// Override in tests to inject mock window data.
    var windowListProvider: () -> [[String: Any]] = MeetingDetector.systemWindowList

    /// Closure to verify a Teams window is a real meeting (not a pop-out chat).
    /// Override in tests to skip AX verification. Default checks for "Leave" button.
    var meetingVerifier: ((_ pid: pid_t) -> Bool) = MeetingDetector.verifyTeamsMeeting

    init(patterns: [AppMeetingPattern], confirmationCount: Int = 2) {
        self.patterns = patterns
        self.confirmationCount = confirmationCount

        var meeting: [String: [NSRegularExpression]] = [:]
        var idle: [String: [NSRegularExpression]] = [:]
        for p in patterns {
            meeting[p.appName] = p.meetingPatterns.map { pattern in
                // These are compile-time constant patterns; a crash here indicates a bug in the pattern definition
                try! NSRegularExpression(pattern: pattern)
            }
            idle[p.appName] = p.idlePatterns.map { pattern in
                try! NSRegularExpression(pattern: pattern)
            }
        }
        self.compiledMeetingPatterns = meeting
        self.compiledIdlePatterns = idle
    }

    /// Single poll: check all windows against all patterns.
    ///
    /// Returns a `DetectedMeeting` only after `confirmationCount` consecutive
    /// positive detections for the same app.
    func checkOnce() -> DetectedMeeting? {
        let windows = windowListProvider()
        var hitsThisRound: Set<String> = []
        // Track first matching window per pattern for returning DetectedMeeting
        var firstMatch: [String: (title: String, window: [String: Any])] = [:]

        for window in windows {
            for pattern in patterns {
                // Skip apps in cooldown (just handled a meeting)
                if let until = cooldownUntil[pattern.appName], Date() < until {
                    continue
                }
                // Only count each pattern once per poll (prevents over-counting
                // when multiple windows match the same app)
                guard !hitsThisRound.contains(pattern.appName) else { continue }

                if let title = matchWindow(window, pattern: pattern) {
                    hitsThisRound.insert(pattern.appName)
                    firstMatch[pattern.appName] = (title, window)
                    consecutiveHits[pattern.appName, default: 0] += 1
                }
            }
        }

        // Check if any pattern reached confirmation threshold
        for (appName, hits) in consecutiveHits {
            if hits >= confirmationCount, let match = firstMatch[appName],
               let pattern = patterns.first(where: { $0.appName == appName }) {
                let pid = match.window["kCGWindowOwnerPID"] as? Int32 ?? 0

                // Verify Teams windows are actual meetings (not pop-out chats)
                if appName == "Microsoft Teams" && !meetingVerifier(pid) {
                    consecutiveHits[appName] = 0
                    continue
                }

                return DetectedMeeting(
                    pattern: pattern,
                    windowTitle: match.title,
                    ownerName: match.window["kCGWindowOwnerName"] as? String ?? "",
                    windowPID: pid
                )
            }
        }

        // Reset counters for apps that had no hit this round
        for appName in consecutiveHits.keys {
            if !hitsThisRound.contains(appName) {
                consecutiveHits[appName] = 0
            }
        }

        return nil
    }

    /// Check if a previously detected meeting is still active.
    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        let windows = windowListProvider()
        for window in windows {
            if matchWindow(window, pattern: meeting.pattern) != nil {
                return true
            }
        }
        return false
    }

    /// Reset confirmation counters and start cooldown for the given app.
    func reset(appName: String? = nil) {
        consecutiveHits.removeAll()
        if let appName {
            cooldownUntil[appName] = Date().addingTimeInterval(cooldownDuration)
        }
    }

    // MARK: - Private

    /// Match a window dict against a meeting pattern. Returns the title if matched.
    private func matchWindow(_ window: [String: Any], pattern: AppMeetingPattern) -> String? {
        guard let owner = window["kCGWindowOwnerName"] as? String,
              pattern.ownerNames.contains(owner) else {
            return nil
        }

        guard let title = window["kCGWindowName"] as? String, !title.isEmpty else {
            return nil
        }

        // Check minimum size
        if let bounds = window["kCGWindowBounds"] as? [String: Any] {
            let width = bounds["Width"] as? CGFloat ?? 0
            let height = bounds["Height"] as? CGFloat ?? 0
            if width < pattern.minWindowWidth || height < pattern.minWindowHeight {
                return nil
            }
        }

        // Skip idle patterns (pre-compiled)
        let range = NSRange(title.startIndex..., in: title)
        if let idleRegexes = compiledIdlePatterns[pattern.appName] {
            for regex in idleRegexes {
                if regex.firstMatch(in: title, range: range) != nil {
                    return nil
                }
            }
        }

        // Match meeting patterns (pre-compiled)
        if let meetingRegexes = compiledMeetingPatterns[pattern.appName] {
            for regex in meetingRegexes {
                if regex.firstMatch(in: title, range: range) != nil {
                    return title
                }
            }
        }

        return nil
    }

    // MARK: - Meeting Verification

    /// Known "Leave" button labels across locales (lowercase).
    private static let leaveLabels = [
        "leave", "verlassen", "leave call", "hang up", "hangup",
        "quitter", "salir", "uscire",  // FR, ES, IT
    ]

    /// Known AX identifiers for the leave/hangup button.
    private static let leaveIdentifiers = [
        "leave-call", "hangup", "leave", "hang-up", "hangup-btn",
        "leave-call-btn", "leave-meeting",
    ]

    /// Verify that a Teams window is actually a meeting (not a pop-out chat).
    /// Checks for a "Leave" button which only exists in meeting windows.
    static func verifyTeamsMeeting(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return true } // can't verify, assume meeting
        let app = AXUIElementCreateApplication(pid)
        let found = findLeaveButton(app) != nil
        if !found {
            logger.info("Teams AX verification: no Leave button found for PID \(pid) — skipping as chat")
        }
        return found
    }

    /// Search AX tree for a button with a leave/hang-up label or identifier.
    private static func findLeaveButton(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 20 { return nil }

        if let role = AXHelper.getAttribute(element, attribute: kAXRoleAttribute) as? String,
           role == kAXButtonRole as String {
            // Check AXIdentifier
            if let id = AXHelper.getAttribute(element, attribute: "AXIdentifier") as? String {
                let lower = id.lowercased()
                if leaveIdentifiers.contains(where: { lower.contains($0) }) {
                    return element
                }
            }
            // Check AXDescription and AXTitle
            for attr in [kAXDescriptionAttribute, kAXTitleAttribute] as [String] {
                if let text = AXHelper.getAttribute(element, attribute: attr) as? String {
                    let lower = text.lowercased()
                    if leaveLabels.contains(where: { lower.hasPrefix($0) }) {
                        return element
                    }
                }
            }
        }

        guard let children = AXHelper.getAttribute(element, attribute: kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findLeaveButton(child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// Default window list provider using CGWindowListCopyWindowInfo.
    static func systemWindowList() -> [[String: Any]] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windowList
    }
}
