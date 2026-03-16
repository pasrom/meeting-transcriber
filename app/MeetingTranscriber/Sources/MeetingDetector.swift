import ApplicationServices
import CoreGraphics
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MeetingDetector")

/// Polls window list to detect active meeting windows.
///
/// Uses CGWindowListCopyWindowInfo to read on-screen windows.
/// Requires Screen Recording permission.
@Observable
class MeetingDetector: MeetingDetecting {
    private let patterns: [AppMeetingPattern]
    private let confirmationCount: Int
    private var consecutiveHits: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private let cooldownDuration: TimeInterval = 5 // brief cooldown to avoid re-detecting the same meeting

    /// Pre-compiled regex for each pattern to avoid re-compilation on every poll.
    private let compiledMeetingPatterns: [String: [NSRegularExpression]]
    private let compiledIdlePatterns: [String: [NSRegularExpression]]

    /// Closure that provides the window list. Defaults to CGWindowListCopyWindowInfo.
    /// Override in tests to inject mock window data.
    var windowListProvider: () -> [[String: Any]] = MeetingDetector.systemWindowList

    /// Closure to verify a Teams window is a real meeting (not a pop-out chat).
    /// Searches the AXWebArea DOM for the hangup button. Override in tests.
    var meetingVerifier: ((_ pid: pid_t) -> Bool) = MeetingDetector.verifyTeamsMeeting

    init(patterns: [AppMeetingPattern], confirmationCount: Int = 2) {
        self.patterns = patterns
        self.confirmationCount = confirmationCount

        var meeting: [String: [NSRegularExpression]] = [:]
        var idle: [String: [NSRegularExpression]] = [:]
        for p in patterns {
            meeting[p.appName] = p.meetingPatterns.map { pattern in
                // swiftlint:disable:next force_try
                try! NSRegularExpression(pattern: pattern)
            }
            idle[p.appName] = p.idlePatterns.map { pattern in
                // swiftlint:disable:next force_try
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
                    windowPID: pid,
                )
            }
        }

        // Reset counters for apps that had no hit this round
        for appName in consecutiveHits.keys where !hitsThisRound.contains(appName) {
            consecutiveHits[appName] = 0
        }

        return nil
    }

    /// Check if a previously detected meeting is still active.
    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        let windows = windowListProvider()
        for window in windows where matchWindow(window, pattern: meeting.pattern) != nil {
            return true
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
            for regex in idleRegexes where regex.firstMatch(in: title, range: range) != nil {
                return nil
            }
        }

        // Match meeting patterns (pre-compiled)
        if let meetingRegexes = compiledMeetingPatterns[pattern.appName] {
            for regex in meetingRegexes where regex.firstMatch(in: title, range: range) != nil {
                return title
            }
        }

        return nil
    }

    // MARK: - Meeting Verification

    /// DOM identifiers that indicate an active Teams call/meeting.
    /// These are stable Electron DOM IDs used by Teams' web content.
    private static let meetingDOMIdentifiers: Set<String> = [
        "hangup-button",
        "microphone-button",
        "video-button",
    ]

    /// Verify that a Teams window is an active meeting by searching the AXWebArea
    /// DOM for call-control buttons (hangup, microphone, video).
    ///
    /// Teams is an Electron app — standard AXButton roles on window chrome don't
    /// expose meeting controls. The web content inside AXWebArea does expose them
    /// via `AXDOMIdentifier`.
    static func verifyTeamsMeeting(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return true } // can't verify, assume meeting
        let app = AXUIElementCreateApplication(pid)
        let found = findMeetingControl(app) != nil
        if !found {
            logger.info("Teams AX verification: no call controls found for PID \(pid) — skipping as chat")
        }
        return found
    }

    /// Search AX tree for an element with a meeting-related AXDOMIdentifier.
    private static func findMeetingControl(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 30 { return nil }

        // Check AXDOMIdentifier (set on Electron/WebView elements)
        if let domId = AXHelper.getAttribute(element, attribute: "AXDOMIdentifier") as? String {
            if meetingDOMIdentifiers.contains(domId) {
                return element
            }
        }

        guard let children = AXHelper.getAttribute(element, attribute: kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findMeetingControl(child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// Default window list provider using CGWindowListCopyWindowInfo.
    static func systemWindowList() -> [[String: Any]] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID,
        ) as? [[String: Any]] else {
            return []
        }
        return windowList
    }
}
