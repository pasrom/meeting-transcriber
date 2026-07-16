import Foundation
import IOKit.pwr_mgt
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PowerAssertionDetector")

/// Detects active meetings via IOKit power assertions.
///
/// Meeting apps (Teams, Zoom, Webex) create `PreventUserIdleDisplaySleep`
/// assertions during calls. This detector reads those assertions via
/// `IOPMCopyAssertionsByProcess()` — sandbox-safe, no entitlement needed.
@Observable
class PowerAssertionDetector: MeetingDetecting {
    /// Known meeting apps and their assertion keywords.
    struct AssertionPattern {
        let appName: String
        let processNames: [String]
        let keywords: [String]
        /// Display-sleep assertion *types* that count as an active call for this
        /// app even when the assertion name carries no keyword. Newer Zoom builds
        /// name their in-call display-sleep assertion with Apple's sample-code
        /// placeholder ("Describe Activity Type"), so "zoom" never appears in the
        /// name; matching the type recovers detection (issue #446). Left empty for
        /// Teams, whose WebView holds a display-sleep "Video Wake Lock" even with
        /// no call in progress, so it must stay keyword-only.
        let assertionTypes: [String]

        init(appName: String, processNames: [String], keywords: [String], assertionTypes: [String] = []) {
            self.appName = appName
            self.processNames = processNames
            self.keywords = keywords
            self.assertionTypes = assertionTypes
        }
    }

    static let defaultPatterns: [AssertionPattern] = [
        AssertionPattern(
            appName: "Microsoft Teams",
            processNames: ["MSTeams", "Microsoft Teams", "Microsoft Teams WebView", "Microsoft Teams (work or school)"],
            keywords: ["call in progress"],
        ),
        AssertionPattern(
            appName: "Zoom",
            processNames: ["zoom.us"],
            keywords: ["zoom"],
            assertionTypes: ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"],
        ),
        AssertionPattern(
            appName: "Webex",
            processNames: ["Webex", "Cisco Webex Meetings", "Meeting Center"],
            keywords: ["webex"],
        ),
        AssertionPattern(
            appName: AppMeetingPattern.simulator.appName,
            processNames: ["meeting-simulator"],
            keywords: ["simulator meeting"],
        ),
    ]

    /// The `defaultPatterns` subset to watch given the user's "Apps to Watch"
    /// toggles (`AppSettings.watchApps`). A user-facing meeting app is kept only
    /// when its name is in `watchedAppNames`; the internal meeting-simulator
    /// pattern is always retained (it is an e2e/test hook, never user-toggleable,
    /// so automated detection keeps working regardless of the toggles). With all
    /// toggles on — the default — this returns every pattern, i.e. unchanged
    /// behaviour; with an empty selection only the simulator remains, so no
    /// user-facing app auto-detects (the user opted them all out).
    static func patterns(watching watchedAppNames: [String]) -> [AssertionPattern] {
        let watched = Set(watchedAppNames)
        return defaultPatterns.filter { pattern in
            pattern.appName == AppMeetingPattern.simulator.appName || watched.contains(pattern.appName)
        }
    }

    private let patterns: [AssertionPattern]
    private let confirmationCount: Int
    private var consecutiveHits: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private let cooldownDuration: TimeInterval = 5
    /// Diagnostic dedup: (process|name|type) keys already logged as unmatched,
    /// so a persistently-running unmatched meeting app logs once per session.
    private var loggedMissKeys: Set<String> = []

    /// Closure that provides assertion data. Defaults to IOPMCopyAssertionsByProcess.
    /// Override in tests to inject mock data.
    var assertionProvider: () -> [Int32: [[String: Any]]] = PowerAssertionDetector.systemAssertions

    /// Closure that provides the window list for title lookup. Defaults to CGWindowListCopyWindowInfo.
    /// Override in tests to inject mock data.
    var windowListProvider: () -> [[String: Any]] = MeetingDetector.systemWindowList

    /// Compiled title matcher per watched app, so the window-title lookup
    /// classifies titles the same way `MeetingDetector` does (idle-tab titles
    /// skipped, meeting-pattern titles preferred).
    private let matchers: [String: MeetingTitleMatcher]

    init(
        patterns: [AssertionPattern] = PowerAssertionDetector.defaultPatterns,
        confirmationCount: Int = 2,
    ) {
        self.patterns = patterns
        self.confirmationCount = confirmationCount
        matchers = patterns.reduce(into: [:]) { dict, pattern in
            guard let meetingPattern = AppMeetingPattern.forAppName(pattern.appName) else {
                // Drift guard: a watched assertion app with no matching
                // AppMeetingPattern would silently title every meeting with the
                // placeholder. Surface it (a consistency test also pins this).
                logger.error(
                    "No AppMeetingPattern for watched app \(pattern.appName, privacy: .public); its meeting titles fall back to the placeholder",
                )
                return
            }
            dict[pattern.appName] = MeetingTitleMatcher(pattern: meetingPattern)
        }
    }

    func checkOnce() -> DetectedMeeting? {
        let assertions = assertionProvider()
        var hitsThisRound: Set<String> = []
        var firstMatch: [String: (pid: Int32, processName: String, assertName: String)] = [:]

        for (pid, pidAssertions) in assertions {
            for assertion in pidAssertions {
                guard let processName = assertion["Process Name"] as? String,
                      let assertName = assertion["AssertName"] as? String else {
                    continue
                }
                let assertType = assertion["AssertType"] as? String ?? ""

                for pattern in patterns {
                    // Skip apps in cooldown
                    if let until = cooldownUntil[pattern.appName], Date() < until {
                        continue
                    }

                    // Only count each pattern once per poll
                    guard !hitsThisRound.contains(pattern.appName) else { continue }

                    if matchAssertion(processName: processName, assertName: assertName, assertType: assertType, pattern: pattern) {
                        hitsThisRound.insert(pattern.appName)
                        firstMatch[pattern.appName] = (pid, processName, assertName)
                        consecutiveHits[pattern.appName, default: 0] += 1
                    }
                }
            }
        }

        logUnmatchedWatchedAssertions(assertions, hits: hitsThisRound)

        // Check confirmation threshold
        for (appName, hits) in consecutiveHits {
            if hits >= confirmationCount, let match = firstMatch[appName] {
                let meetingPattern = AppMeetingPattern.forAppName(appName) ?? AppMeetingPattern(
                    appName: appName,
                    ownerNames: [match.processName],
                    meetingPatterns: [],
                )
                let title = lookupWindowTitle(appName: appName) ?? match.assertName
                return DetectedMeeting(
                    pattern: meetingPattern,
                    windowTitle: title,
                    ownerName: match.processName,
                    windowPID: match.pid,
                )
            }
        }

        // Reset counters for apps with no hit this round
        for appName in consecutiveHits.keys where !hitsThisRound.contains(appName) {
            consecutiveHits[appName] = 0
        }

        return nil
    }

    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        let assertions = assertionProvider()
        for (_, pidAssertions) in assertions {
            for assertion in pidAssertions {
                guard let processName = assertion["Process Name"] as? String,
                      let assertName = assertion["AssertName"] as? String else {
                    continue
                }
                let assertType = assertion["AssertType"] as? String ?? ""
                for pattern in patterns where pattern.appName == meeting.pattern.appName {
                    if matchAssertion(processName: processName, assertName: assertName, assertType: assertType, pattern: pattern) {
                        return true
                    }
                }
            }
        }
        return false
    }

    func reset(appName: String? = nil) {
        consecutiveHits.removeAll()
        if let appName {
            cooldownUntil[appName] = Date().addingTimeInterval(cooldownDuration)
        }
    }

    // MARK: - Window Title Lookup

    /// Look up the actual meeting-window title for a detected app via
    /// CGWindowListCopyWindowInfo. Prefers a meeting-pattern window (a 1:1 call
    /// window carries the other person's name), skips idle-tab titles (Teams'
    /// Calendar tab etc.), and returns nil when nothing usable is found so the
    /// caller can substitute a placeholder instead of the raw assertion name.
    private func lookupWindowTitle(appName: String) -> String? {
        matchers[appName]?.selectWindowTitle(from: windowListProvider())
    }

    // MARK: - Private

    private func matchAssertion(processName: String, assertName: String, assertType: String, pattern: AssertionPattern) -> Bool {
        guard pattern.processNames.contains(processName) else { return false }
        let lowerAssert = assertName.lowercased()
        if pattern.keywords.contains(where: { lowerAssert.contains($0.lowercased()) }) {
            return true
        }
        return pattern.assertionTypes.contains(assertType)
    }

    /// Keys ("process|name|type") for assertions from a watched meeting app that
    /// produced no match this round. Pure so the selection logic is unit-testable;
    /// the caller dedupes for the detector's lifetime and emits one log line each.
    static func unmatchedWatchedAssertionKeys(
        assertions: [Int32: [[String: Any]]],
        patterns: [AssertionPattern],
        hits: Set<String>,
    ) -> [String] {
        let watched = Set(patterns.flatMap(\.processNames))
        var keys: [String] = []
        for pidAssertions in assertions.values {
            for assertion in pidAssertions {
                guard let processName = assertion["Process Name"] as? String,
                      watched.contains(processName),
                      let pattern = patterns.first(where: { $0.processNames.contains(processName) }),
                      !hits.contains(pattern.appName) else {
                    continue
                }
                let assertName = assertion["AssertName"] as? String ?? ""
                let assertType = assertion["AssertType"] as? String ?? ""
                keys.append("\(processName)|\(assertName)|\(assertType)")
            }
        }
        return keys
    }

    /// Log, once per distinct key, that a watched meeting app is running but its
    /// assertion matched nothing this round — the "detection silently not firing"
    /// signal from issue #446, previously visible only via manual pmset. The
    /// names are app/OS-generated metadata (no user content), logged `.public`
    /// so a reporter's diagnostic export names the actual assertion.
    private func logUnmatchedWatchedAssertions(_ assertions: [Int32: [[String: Any]]], hits: Set<String>) {
        for key in Self.unmatchedWatchedAssertionKeys(assertions: assertions, patterns: patterns, hits: hits) {
            guard loggedMissKeys.insert(key).inserted else { continue }
            logger.info("""
            Watched meeting app is running but its power assertion did not match \
            (process|name|type = \(key, privacy: .public)); \
            if a meeting is active, detection is not firing.
            """)
        }
    }

    /// Default assertion provider using IOPMCopyAssertionsByProcess.
    ///
    /// The API returns a CFDictionary keyed by PID (CFNumber), not String.
    /// We extract keys/values manually via CFDictionaryGetKeysAndValues.
    static func systemAssertions() -> [Int32: [[String: Any]]] {
        var assertionsByProcess: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard status == kIOReturnSuccess, let raw = assertionsByProcess else {
            return [:]
        }

        let cfDict = raw.takeRetainedValue()
        let count = CFDictionaryGetCount(cfDict)
        guard count > 0 else { return [:] }

        let keys = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        let values = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: count)
        defer {
            keys.deallocate()
            values.deallocate()
        }
        CFDictionaryGetKeysAndValues(cfDict, keys, values)

        var result: [Int32: [[String: Any]]] = [:]
        for i in 0 ..< count {
            guard let valPtr = values[i] else { continue }
            guard let keyPtr = keys[i] else { continue }
            let keyObj = Unmanaged<AnyObject>.fromOpaque(keyPtr).takeUnretainedValue()
            let pid = keyObj as? Int32 ?? 0
            let valObj = Unmanaged<AnyObject>.fromOpaque(valPtr).takeUnretainedValue()
            if let assertions = valObj as? [[String: Any]] {
                result[pid] = assertions
            }
        }
        return result
    }
}
