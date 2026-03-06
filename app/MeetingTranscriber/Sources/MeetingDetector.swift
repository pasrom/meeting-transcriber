import CoreGraphics
import Foundation

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
    private let cooldownDuration: TimeInterval = 60  // ignore same app for 60s after meeting

    /// Names of all active patterns (for debug logging).
    var patternNames: [String] { patterns.map(\.appName) }

    /// Closure that provides the window list. Defaults to CGWindowListCopyWindowInfo.
    /// Override in tests to inject mock window data.
    var windowListProvider: () -> [[String: Any]] = MeetingDetector.systemWindowList

    init(patterns: [AppMeetingPattern], confirmationCount: Int = 2) {
        self.patterns = patterns
        self.confirmationCount = confirmationCount
    }

    /// Single poll: check all windows against all patterns.
    ///
    /// Returns a `DetectedMeeting` only after `confirmationCount` consecutive
    /// positive detections for the same app.
    func checkOnce() -> DetectedMeeting? {
        let windows = windowListProvider()
        var hitsThisRound: Set<String> = []

        for window in windows {
            for pattern in patterns {
                // Skip apps in cooldown (just handled a meeting)
                if let until = cooldownUntil[pattern.appName], Date() < until {
                    continue
                }
                if let title = matchWindow(window, pattern: pattern) {
                    hitsThisRound.insert(pattern.appName)
                    consecutiveHits[pattern.appName, default: 0] += 1

                    if consecutiveHits[pattern.appName, default: 0] >= confirmationCount {
                        let pid = window["kCGWindowOwnerPID"] as? Int32 ?? 0
                        return DetectedMeeting(
                            pattern: pattern,
                            windowTitle: title,
                            ownerName: window["kCGWindowOwnerName"] as? String ?? "",
                            windowPID: pid
                        )
                    }
                }
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

        // Skip idle patterns
        for idlePattern in pattern.idlePatterns {
            if title.range(of: idlePattern, options: .regularExpression) != nil {
                return nil
            }
        }

        // Match meeting patterns
        for meetingPattern in pattern.meetingPatterns {
            if title.range(of: meetingPattern, options: .regularExpression) != nil {
                return title
            }
        }

        return nil
    }

    /// Default window list provider using CGWindowListCopyWindowInfo.
    static func systemWindowList() -> [[String: Any]] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windowList
    }
}
