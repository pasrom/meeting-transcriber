import Foundation
import IOKit.pwr_mgt
import os.log

// swiftlint:disable:next unused_declaration
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
    }

    static let defaultPatterns: [AssertionPattern] = [
        AssertionPattern(
            appName: "Microsoft Teams",
            processNames: ["MSTeams", "Microsoft Teams", "Microsoft Teams WebView", "Microsoft Teams (work or school)"],
            keywords: ["call in progress"]
        ),
        AssertionPattern(
            appName: "Zoom",
            processNames: ["zoom.us", "CptHost"],
            keywords: ["zoom"]
        ),
        AssertionPattern(
            appName: "Webex",
            processNames: ["Webex", "Cisco Webex Meetings", "Meeting Center"],
            keywords: ["webex"]
        ),
    ]

    private let patterns: [AssertionPattern]
    private let confirmationCount: Int
    private var consecutiveHits: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private let cooldownDuration: TimeInterval = 5

    /// Closure that provides assertion data. Defaults to IOPMCopyAssertionsByProcess.
    /// Override in tests to inject mock data.
    var assertionProvider: () -> [Int32: [[String: Any]]] = PowerAssertionDetector.systemAssertions

    /// Last detected meeting, kept for isMeetingActive checks.
    private var lastDetectedAppName: String?

    init(
        patterns: [AssertionPattern] = PowerAssertionDetector.defaultPatterns,
        confirmationCount: Int = 2,
    ) {
        self.patterns = patterns
        self.confirmationCount = confirmationCount
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

                for pattern in patterns {
                    // Skip apps in cooldown
                    if let until = cooldownUntil[pattern.appName], Date() < until {
                        continue
                    }

                    // Only count each pattern once per poll
                    guard !hitsThisRound.contains(pattern.appName) else { continue }

                    if matchAssertion(processName: processName, assertName: assertName, pattern: pattern) {
                        hitsThisRound.insert(pattern.appName)
                        firstMatch[pattern.appName] = (pid, processName, assertName)
                        consecutiveHits[pattern.appName, default: 0] += 1
                    }
                }
            }
        }

        // Check confirmation threshold
        for (appName, hits) in consecutiveHits {
            if hits >= confirmationCount, let match = firstMatch[appName] {
                let meetingPattern = AppMeetingPattern.forAppName(appName) ?? AppMeetingPattern(
                    appName: appName,
                    ownerNames: [match.processName],
                    meetingPatterns: []
                )
                lastDetectedAppName = appName
                return DetectedMeeting(
                    pattern: meetingPattern,
                    windowTitle: match.assertName,
                    ownerName: match.processName,
                    windowPID: match.pid
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
                for pattern in patterns where pattern.appName == meeting.pattern.appName {
                    if matchAssertion(processName: processName, assertName: assertName, pattern: pattern) {
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

    // MARK: - Private

    private func matchAssertion(processName: String, assertName: String, pattern: AssertionPattern) -> Bool {
        guard pattern.processNames.contains(processName) else { return false }
        let lowerAssert = assertName.lowercased()
        return pattern.keywords.contains { lowerAssert.contains($0.lowercased()) }
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
            let keyObj = Unmanaged<AnyObject>.fromOpaque(keys[i]!).takeUnretainedValue()
            let pid = (keyObj as? NSNumber)?.int32Value ?? 0
            let valObj = Unmanaged<AnyObject>.fromOpaque(valPtr).takeUnretainedValue()
            if let assertions = valObj as? [[String: Any]] {
                result[pid] = assertions
            }
        }
        return result
    }
}
