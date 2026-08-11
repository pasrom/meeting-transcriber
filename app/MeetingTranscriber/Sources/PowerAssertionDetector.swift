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
        /// How a hit is carried downstream. Deliberately independent of
        /// `processNames`: a pattern can accept a fixed list of processes and
        /// still identify each of them separately.
        let identity: Identity

        /// `.shared`: every process in `processNames` is the same app, so the
        /// pattern's own `appName` is the identity (Teams is one app whether it
        /// asserts as `MSTeams` or `Microsoft Teams`). `.perProcess`: each
        /// process is its own app, so the concrete process name is the identity.
        /// Browser meetings are `.perProcess` because the Chromium forks that
        /// share this pattern are *different browsers*, not aliases of one:
        /// aliasing them made a decline in one silence the others, let one keep
        /// another's recording alive, and let one supply another's window title.
        enum Identity {
            case shared
            case perProcess
        }

        init(
            appName: String,
            processNames: [String],
            keywords: [String],
            assertionTypes: [String] = [],
            identity: Identity = .shared,
        ) {
            self.appName = appName
            self.processNames = processNames
            self.keywords = keywords
            self.assertionTypes = assertionTypes
            self.identity = identity
        }

        /// The key every per-app piece of detector state is filed under:
        /// confirmation counts, cooldowns, the once-per-poll guard and the
        /// winning match. See `Identity`.
        func identityKey(processName: String) -> String {
            switch identity {
            case .shared: appName
            case .perProcess: processName
            }
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
        // Browser meetings (issue #503): a Chromium browser holds a
        // "NoIdleSleepAssertion" named "WebRTC has active PeerConnections"
        // during any WebRTC call (Google Meet, Whereby, web Zoom/Teams/Webex).
        // The assertion lives in Chromium's content layer, so every fork emits
        // the same name. `processNames` is therefore EMPTY: the name is the
        // signal, and listing forks only meant a new one needed a release, with
        // a wrong name failing silently. Any process claiming an active
        // PeerConnection is a candidate; the consent prompt and its "Never for
        // this app" action are the filter, which is what makes it safe to let
        // Electron apps through (`matches` excludes native meeting clients, see
        // there). `.perProcess` carries each browser as itself, so a call in one
        // cannot silence, prolong, mistitle or misattribute a call in another.
        // Keyword-only, no assertionTypes: a Chromium browser holds the same
        // assertion type for plain media playback (YouTube), so matching the
        // type would fire on every video. Opt-in: only watched when the browser
        // toggle adds the category token to watchApps.
        AssertionPattern(
            appName: AppMeetingPattern.browserMeetings.appName,
            processNames: [], // process-open: see `matches`
            keywords: ["webrtc", "peerconnection"],
            identity: .perProcess,
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

    /// See `claimedProcesses(in:)`. From `defaultPatterns`, not `patterns`.
    private let claimedProcesses = PowerAssertionDetector.claimedProcesses(
        in: PowerAssertionDetector.defaultPatterns,
    )

    init(
        patterns: [AssertionPattern] = PowerAssertionDetector.defaultPatterns,
        confirmationCount: Int = 2,
    ) {
        self.patterns = patterns
        self.confirmationCount = confirmationCount
        matchers = patterns.reduce(into: [:]) { dict, pattern in
            // `.perProcess` patterns build their matcher per hit from the
            // concrete process, so there is nothing to precompile and nothing
            // for the drift guard below to complain about.
            guard pattern.identity == .shared else { return }
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
        var firstMatch: [String: (pid: Int32, processName: String, pattern: AssertionPattern)] = [:]

        for (pid, pidAssertions) in assertions {
            for assertion in pidAssertions {
                guard let processName = assertion["Process Name"] as? String,
                      let assertName = assertion["AssertName"] as? String else {
                    continue
                }
                let assertType = assertion["AssertType"] as? String ?? ""

                for pattern in patterns {
                    // Every piece of per-app state below is filed under the
                    // identity key, not the pattern name, so two browsers
                    // sharing the browser pattern never share a slot.
                    let key = pattern.identityKey(processName: processName)

                    // Skip apps in cooldown
                    if let until = cooldownUntil[key], Date() < until {
                        continue
                    }

                    // Only count each identity once per poll
                    guard !hitsThisRound.contains(key) else { continue }

                    if matchAssertion(processName: processName, assertName: assertName, assertType: assertType, pattern: pattern) {
                        hitsThisRound.insert(key)
                        firstMatch[key] = (pid, processName, pattern)
                        consecutiveHits[key, default: 0] += 1
                    }
                }
            }
        }

        logUnmatchedWatchedAssertions(assertions, hits: hitsThisRound)

        // Check confirmation threshold
        for (key, hits) in consecutiveHits {
            if hits >= confirmationCount, let match = firstMatch[key] {
                let meetingPattern = Self.meetingIdentity(
                    pattern: match.pattern, processName: match.processName,
                )
                let title = lookupWindowTitle(for: meetingPattern, pattern: match.pattern)
                    ?? Self.placeholderTitle(appName: meetingPattern.appName)
                return DetectedMeeting(
                    pattern: meetingPattern,
                    windowTitle: title,
                    ownerName: match.processName,
                    windowPID: match.pid,
                )
            }
        }

        // Reset counters for identities with no hit this round
        for key in consecutiveHits.keys where !hitsThisRound.contains(key) {
            consecutiveHits[key] = 0
        }

        return nil
    }

    /// The `AppMeetingPattern` a confirmed hit is carried under.
    ///
    /// `.shared` patterns resolve their declared app, keeping today's behaviour.
    /// `.perProcess` patterns synthesise a pattern for the concrete process.
    ///
    /// The synthesis MUST carry the category's `requiresRecordingConsent`
    /// forward. `AppMeetingPattern`'s initializer defaults it to false, and a
    /// synthesised browser identity that dropped the flag would auto-record a
    /// call with no prompt, which is the exact inverse of the browser-meeting
    /// safety story. `testPerProcessIdentityKeepsTheConsentRequirement` pins it.
    static func meetingIdentity(pattern: AssertionPattern, processName: String) -> AppMeetingPattern {
        let category = AppMeetingPattern.forAppName(pattern.appName)
        switch pattern.identity {
        case .shared:
            return category ?? AppMeetingPattern(
                appName: pattern.appName,
                ownerNames: [processName],
                meetingPatterns: [],
            )

        case .perProcess:
            return AppMeetingPattern(
                appName: processName,
                ownerNames: [processName],
                meetingPatterns: [],
                requiresRecordingConsent: category?.requiresRecordingConsent ?? false,
            )
        }
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
                // Same rule as `checkOnce`: an assertion keeps this meeting
                // alive only when it resolves to the SAME identity. Comparing
                // `pattern.appName` would compare a category token against a
                // process name for `.perProcess` patterns, so nothing would ever
                // match and every browser recording would stop at the end grace.
                for pattern in patterns
                    where pattern.identityKey(processName: processName) == meeting.pattern.appName {
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

    /// Clean fallback title when no usable window title is found (e.g. Screen
    /// Recording denied, or the app exposes only idle windows). Preferred over
    /// the raw assertion name, which is often an internal placeholder
    /// (Zoom's "Describe Activity Type") or a status string.
    static func placeholderTitle(appName: String) -> String {
        "\(appName) Call"
    }

    /// Look up the actual meeting-window title for a detected app via
    /// CGWindowListCopyWindowInfo. Prefers a meeting-pattern window (a 1:1 call
    /// window carries the other person's name), skips idle-tab titles (Teams'
    /// Calendar tab etc.), and returns nil when nothing usable is found so the
    /// caller can substitute a placeholder instead of the raw assertion name.
    /// `.shared` patterns use the matcher compiled at init. `.perProcess` hits
    /// build one from the synthesised identity, whose `ownerNames` is exactly
    /// the one process that asserted, so only that browser's own windows can
    /// supply the title. A shared owner list would let any fork in the family
    /// contribute, which is how an unrelated tab title reached the protocol
    /// filename and the model prompt. Building it costs nothing: the
    /// synthesised pattern carries no regexes to compile.
    private func lookupWindowTitle(
        for meetingPattern: AppMeetingPattern,
        pattern: AssertionPattern,
    ) -> String? {
        let matcher = switch pattern.identity {
        case .shared: matchers[pattern.appName]
        case .perProcess: MeetingTitleMatcher(pattern: meetingPattern)
        }
        return matcher?.selectWindowTitle(from: windowListProvider())
    }

    // MARK: - Private

    /// Processes a bound pattern already speaks for. A process-open pattern can
    /// never take one of these, so a native client cannot also be seen as a
    /// browser meeting.
    ///
    /// Always computed from ALL known patterns, never from the watched subset:
    /// otherwise switching the Teams toggle off would hand Teams to the browser
    /// path and record it anyway, against the user's explicit opt-out.
    static func claimedProcesses(in patterns: [AssertionPattern]) -> Set<String> {
        Set(patterns.flatMap(\.processNames))
    }

    /// Whether one assertion matches one pattern.
    ///
    /// Bound patterns check the process first, as before. Process-open patterns
    /// accept any process except one claimed by a bound pattern: Teams is
    /// Electron and plausibly holds the identical WebRTC assertion during a
    /// call, so without the exclusion a native Teams call would fire twice, once
    /// auto-starting under its own pattern and once prompting as a browser
    /// meeting.
    ///
    /// The exclusion is keyed on the process, not the service, which is what
    /// keeps web meetings working: Zoom, Teams or Webex taken in a browser hold
    /// the assertion under the browser, and no native pattern claims a browser.
    static func matches(
        pattern: AssertionPattern,
        processName: String,
        assertName: String,
        assertType: String,
        claimed: Set<String>,
    ) -> Bool {
        if pattern.processNames.isEmpty {
            guard !claimed.contains(processName) else { return false }
        } else {
            guard pattern.processNames.contains(processName) else { return false }
        }
        let lowerAssert = assertName.lowercased()
        if pattern.keywords.contains(where: { lowerAssert.contains($0.lowercased()) }) {
            return true
        }
        return pattern.assertionTypes.contains(assertType)
    }

    private func matchAssertion(processName: String, assertName: String, assertType: String, pattern: AssertionPattern) -> Bool {
        Self.matches(
            pattern: pattern,
            processName: processName,
            assertName: assertName,
            assertType: assertType,
            claimed: claimedProcesses,
        )
    }

    /// Keys ("process|name|type") for assertions from a watched meeting app that
    /// produced no match this round. Pure so the selection logic is unit-testable;
    /// the caller dedupes for the detector's lifetime and emits one log line each.
    static func unmatchedWatchedAssertionKeys(
        assertions: [Int32: [[String: Any]]],
        patterns: [AssertionPattern],
        hits: Set<String>,
    ) -> [String] {
        var keys: [String] = []
        for pidAssertions in assertions.values {
            for assertion in pidAssertions {
                guard let processName = assertion["Process Name"] as? String else { continue }
                let assertName = assertion["AssertName"] as? String ?? ""
                let assertType = assertion["AssertType"] as? String ?? ""
                guard patterns.contains(where: { pattern in
                    interesting(
                        pattern: pattern,
                        processName: processName,
                        assertName: assertName,
                        hits: hits,
                    )
                }) else { continue }
                keys.append("\(processName)|\(assertName)|\(assertType)")
            }
        }
        return keys
    }

    /// Whether this assertion is worth telling the user about: it looks like a
    /// meeting for `pattern` but produced no detection this round.
    ///
    /// Two arms. A bound pattern reports its own processes, as before. A
    /// process-open pattern reports ANY process whose assertion NAME carries its
    /// keywords, whoever holds it, which is the arm that did not exist: the
    /// diagnostic used to be gated on the same allowlist it was meant to
    /// diagnose, so a process that failed to match produced no log line at all
    /// and a wrong or missing browser name was invisible from the outside. A
    /// natively-claimed process is included on purpose: "we saw a WebRTC
    /// assertion from Teams and deliberately did not act on it" is exactly the
    /// kind of thing a support log should say.
    private static func interesting(
        pattern: AssertionPattern,
        processName: String,
        assertName: String,
        hits: Set<String>,
    ) -> Bool {
        guard !hits.contains(pattern.identityKey(processName: processName)) else { return false }
        if pattern.processNames.isEmpty {
            let lowered = assertName.lowercased()
            return pattern.keywords.contains { lowered.contains($0.lowercased()) }
        }
        return pattern.processNames.contains(processName)
    }

    /// Log, once per distinct key, that a watched meeting app is running but its
    /// assertion matched nothing this round — the "detection silently not firing"
    /// signal from issue #446, previously visible only via manual pmset. The
    /// names are app/OS-generated metadata (no user content), logged `.public`
    /// so a reporter's diagnostic export names the actual assertion.
    private func logUnmatchedWatchedAssertions(_ assertions: [Int32: [[String: Any]]], hits: Set<String>) {
        for key in Self.unmatchedWatchedAssertionKeys(
            assertions: assertions, patterns: patterns, hits: hits,
        ) {
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
