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
        /// Whether each call gets assertions with fresh IDs, so an unseen ID
        /// means a new call (issue #765). On only where measured (Teams):
        /// Zoom also matches by type, and an unrelated assertion recreated
        /// mid-call would split one call in two.
        let assertionIdentifiesCall: Bool

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

        /// Keywords pre-lowercased once, because `matches` runs for every
        /// assertion on the machine on every poll and these are constants.
        private let loweredKeywords: [String]

        init(
            appName: String,
            processNames: [String],
            keywords: [String],
            assertionTypes: [String] = [],
            identity: Identity = .shared,
            assertionIdentifiesCall: Bool = false,
        ) {
            // A process-open pattern MUST identify per process. Shared identity
            // would file every unclaimed process on the machine into one
            // confirmation counter and one cooldown slot, so two unrelated apps
            // alternating across polls would confirm a meeting that never
            // existed, and the title lookup would use a matcher compiled from a
            // category with no owner names and so return nil forever. Nothing
            // else rules the combination out, and it is the shortest spelling of
            // a new open pattern, so it is trapped here.
            assert(
                !(processNames.isEmpty && identity == .shared),
                "a process-open pattern must use .perProcess identity",
            )
            self.appName = appName
            self.processNames = processNames
            self.keywords = keywords
            self.assertionTypes = assertionTypes
            self.identity = processNames.isEmpty ? .perProcess : identity
            self.assertionIdentifiesCall = assertionIdentifiesCall
            loweredKeywords = keywords.map { $0.lowercased() }
        }

        /// Whether this pattern's keywords appear in an assertion name.
        func matchesKeyword(in assertName: String) -> Bool {
            let lowered = assertName.lowercased()
            return loweredKeywords.contains { lowered.contains($0) }
        }

        /// The key every per-app piece of detector state is filed under:
        /// confirmation counts, cooldowns, the once-per-poll guard and the
        /// winning match. See `Identity`.
        /// NOTE: the two arms draw from different namespaces — `.shared` yields
        /// an app name we choose, `.perProcess` an executable name off the
        /// assertion, which since matching went process-open is unbounded. A
        /// process literally named "Zoom" or "WhatsApp" therefore shares a
        /// confirmation counter and a cooldown with the native app of that name.
        /// Narrow in practice (such a process is almost certainly that app, and
        /// claimed processes are excluded from open matching anyway), and NOT
        /// fixed by prefixing the key here: `reset(appName:)` writes the cooldown
        /// from a bare identity string and cannot know which kind it is, so a
        /// prefix silently stops every cooldown from applying. Fixing it properly
        /// means carrying the identity kind through that API.
        func identityKey(processName: String) -> String {
            switch identity {
            case .shared: appName
            case .perProcess: processName
            }
        }

        /// Whether an assertion held by `processName` belongs to the same
        /// identity as a meeting already detected under `meetingAppName`.
        ///
        /// `meetingAppName` is already the identity (`DetectedMeeting.pattern`
        /// carries the process name for a per-process hit), so it is compared
        /// against this assertion's key directly. It must NOT be run back
        /// through `identityKey`: that arm ignores its argument for `.shared`
        /// patterns, so both sides would collapse to `appName` and the predicate
        /// would be true for every pattern, leaving `isMeetingActive` with no
        /// filter at all and letting any watched app's call keep any other
        /// app's finished recording running.
        func identifies(meetingAppName: String, processName: String) -> Bool {
            identityKey(processName: processName) == meetingAppName
        }
    }

    static let defaultPatterns: [AssertionPattern] = [
        AssertionPattern(
            appName: "Microsoft Teams",
            processNames: ["MSTeams", "Microsoft Teams", "Microsoft Teams WebView", "Microsoft Teams (work or school)"],
            keywords: ["call in progress"],
            assertionIdentifiesCall: true,
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
            // Cisco names the call assertion "On a call", not "webex" (measured:
            // Webex 46.7.0.35472 on macOS 26.5.2). Keyword-only like Teams, so
            // the #475 concern does not arise; bound to processNames above.
            keywords: ["webex", "on a call"],
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
    /// The keys the last poll reported as "did not match". Read by tests; the
    /// log line is emitted from the same list.
    private(set) var lastUnmatchedKeys: [String] = []

    /// Closure that provides assertion data. Defaults to IOPMCopyAssertionsByProcess.
    /// Override in tests to inject mock data.
    var assertionProvider: () -> [Int32: [[String: Any]]] = PowerAssertionDetector.systemAssertions

    /// Closure that provides the window list for title lookup. Defaults to CGWindowListCopyWindowInfo.
    /// Override in tests to inject mock data.
    var windowListProvider: () -> [[String: Any]] = MeetingDetector.systemWindowList

    /// Identities the user answered "Never for this app" about, so they never
    /// reach confirmation. Wired from the persisted deny list.
    ///
    /// Filtered here rather than only at the consent gate because a denial does
    /// not expire. An app that holds a WebRTC assertion all day would otherwise
    /// re-confirm every few polls forever, and each time the gate skipped it it
    /// called `reset`, which clears the confirmation counters of EVERY app: a
    /// Teams or Zoom call starting in one of those windows would lose its
    /// accumulated count and be detected late or not at all. A denied identity
    /// also cannot occupy the single consent slot or a poll's one returned
    /// meeting if it never confirms.
    var isIdentityDenied: (String) -> Bool = { _ in false }

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
        // Every identity whose assertion matched, including the ones skipped
        // on purpose below (denied, or cooling down after a reset). Those are
        // not misses, and the diagnostic must not call them "did not match"
        // (issue #814); it reads this set, not `hitsThisRound`.
        var matchedThisRound: Set<String> = []
        var firstMatch: [String: Hit] = [:]

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

                    // Only count each identity once per poll
                    guard !matchedThisRound.contains(key),
                          matchAssertion(
                              processName: processName, assertName: assertName, assertType: assertType, pattern: pattern,
                          ) else { continue }
                    matchedThisRound.insert(key)

                    // Permanently refused: never confirm, so it cannot shadow
                    // another meeting or force a counter-wiping reset.
                    if isIdentityDenied(key) {
                        logDeniedOnce(key)
                        continue
                    }

                    // Skip apps in cooldown
                    if let until = cooldownUntil[key], Date() < until {
                        continue
                    }

                    hitsThisRound.insert(key)
                    firstMatch[key] = (pid, processName, pattern)
                    consecutiveHits[key, default: 0] += 1
                }
            }
        }

        logUnmatchedWatchedAssertions(assertions, matched: matchedThisRound)

        // Reset counters for identities with no hit this round. Before the
        // pick, not after: returning a meeting used to skip this, and the
        // parked browser call is returned on every poll, so a stale single
        // hit survived for minutes and the next hit confirmed in one poll
        // instead of `confirmationCount` consecutive ones.
        for key in consecutiveHits.keys where !hitsThisRound.contains(key) {
            consecutiveHits[key] = 0
        }

        // Check confirmation threshold. One meeting per poll, and not in
        // dictionary order: a browser call whose consent prompt is parked
        // re-confirms on every poll and is skipped by the loop each time, so
        // the slot must go to a meeting that can start now (issue #814). The
        // `firstMatch` entries are this round's hits, so they are the
        // candidates.
        let confirmed = firstMatch.compactMap { key, match -> Candidate? in
            guard consecutiveHits[key, default: 0] >= confirmationCount else { return nil }
            let identity = Self.meetingIdentity(pattern: match.pattern, processName: match.processName)
            return Candidate(key: key, match: match, identity: identity)
        }
        if let pick = confirmed.min(by: { Self.startRank($0) < Self.startRank($1) }) {
            let title = lookupWindowTitle(for: pick.identity, pattern: pick.match.pattern)
                ?? Self.placeholderTitle(appName: pick.identity.appName)
            return DetectedMeeting(
                pattern: pick.identity,
                windowTitle: title,
                ownerName: pick.match.processName,
                windowPID: pick.match.pid,
            )
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
            if category == nil {
                // The drift guard in `init` only inspects `.shared` patterns, so
                // a per-process pattern whose category `appName` does not resolve
                // (a typo, or a rename applied on one side only) would otherwise
                // fall to the initializer's `false` default and auto-record with
                // no prompt. Fail towards asking.
                logger.error(
                    "No AppMeetingPattern for process-open category \(pattern.appName, privacy: .public); requiring consent",
                )
            }
            return AppMeetingPattern(
                appName: processName,
                ownerNames: [processName],
                meetingPatterns: [],
                requiresRecordingConsent: category?.requiresRecordingConsent ?? true,
            )
        }
    }

    /// What one poll recorded for an identity's first matching assertion.
    private typealias Hit = (pid: Int32, processName: String, pattern: AssertionPattern)

    /// An identity over the confirmation threshold in one poll.
    private struct Candidate {
        let key: String
        let match: Hit
        let identity: AppMeetingPattern
    }

    /// Order among the candidates of one poll: a meeting that records without
    /// asking before one that waits for consent, then by identity key, so the
    /// pick is the same from one poll to the next.
    private static func startRank(_ candidate: Candidate) -> (Int, String) {
        (candidate.identity.requiresRecordingConsent ? 1 : 0, candidate.key)
    }

    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        assertionProvider().values.joined().contains { matchingPattern(of: $0, for: meeting) != nil }
    }

    func activeCalls(_ meeting: DetectedMeeting) -> ActiveCalls {
        let identifiesCall = patterns.contains { pattern in
            pattern.assertionIdentifiesCall
                && pattern.identifies(meetingAppName: meeting.pattern.appName, processName: meeting.ownerName)
        }
        guard identifiesCall else { return .unidentified }
        var ids: Set<String> = []
        for assertion in assertionProvider().values.joined() {
            guard let pattern = matchingPattern(of: assertion, for: meeting) else { continue }
            // An assertion without an ID, or from a pattern whose IDs do not
            // track calls, cannot be told apart from the next call's.
            guard pattern.assertionIdentifiesCall, let id = assertion["AssertionId"] as? Int else {
                return .unidentified
            }
            ids.insert(String(id))
        }
        return .ids(ids)
    }

    /// The pattern through which `assertion` keeps `meeting` alive, if any.
    private func matchingPattern(of assertion: [String: Any], for meeting: DetectedMeeting) -> AssertionPattern? {
        guard let processName = assertion["Process Name"] as? String,
              let assertName = assertion["AssertName"] as? String else {
            return nil
        }
        let assertType = assertion["AssertType"] as? String ?? ""
        // Same rule as `checkOnce`: an assertion keeps this meeting
        // alive only when it resolves to the SAME identity. Comparing
        // `pattern.appName` would compare a category token against a
        // process name for `.perProcess` patterns, so nothing would ever
        // match and every browser recording would stop at the end grace.
        return patterns.first { pattern in
            pattern.identifies(meetingAppName: meeting.pattern.appName, processName: processName)
                && matchAssertion(processName: processName, assertName: assertName, assertType: assertType, pattern: pattern)
        }
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

    /// Processes that belong to an app the user can watch in its own right. A
    /// process-open pattern can never take one of these, so a native client is
    /// never also seen as a browser meeting.
    ///
    /// Two sources, because an app can be known to this detector, to
    /// `MicInputDetector`, or to both: the bound assertion patterns here, plus
    /// every `AppMeetingPattern.ownerNames`, which is where the mic-detected
    /// call apps (WeChat, WhatsApp, FaceTime, Tencent Meeting) are declared.
    /// WhatsApp in particular is Electron and so a plausible holder of the very
    /// assertion the open pattern keys on.
    ///
    /// Always from ALL known apps, never from the watched subset. Otherwise
    /// switching an app's toggle off would hand it to the browser path and
    /// record it anyway, against the user's explicit opt-out, which is the one
    /// thing this exclusion exists to prevent.
    static let claimedProcesses: Set<String> = Set(
        defaultPatterns.flatMap(\.processNames) + AppMeetingPattern.all.flatMap(\.ownerNames),
    )

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
    ) -> Bool {
        if pattern.processNames.isEmpty {
            // The name becomes the identity, the prompt body and the deny-list
            // key, so a blank one would ask "A meeting is active in ." and store
            // an unremovable blank row. The allowlist used to make this
            // unreachable.
            guard !processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            guard !claimedProcesses.contains(processName) else { return false }
        } else {
            guard pattern.processNames.contains(processName) else { return false }
        }
        if pattern.matchesKeyword(in: assertName) { return true }
        return pattern.assertionTypes.contains(assertType)
    }

    private func matchAssertion(processName: String, assertName: String, assertType: String, pattern: AssertionPattern) -> Bool {
        Self.matches(pattern: pattern, processName: processName, assertName: assertName, assertType: assertType)
    }

    /// One line per denied identity per session, naming the list that holds
    /// it, so a refused app is not mistaken for one the detector cannot see.
    private func logDeniedOnce(_ identity: String) {
        guard loggedMissKeys.insert("denied|\(identity)").inserted else { return }
        logger.info("""
        Meeting assertion from \(identity, privacy: .public) matched but is ignored: \
        the app is on the "Never for this app" list (Settings → General).
        """)
    }

    private func logUnmatchedWatchedAssertions(_ assertions: [Int32: [[String: Any]]], matched: Set<String>) {
        lastUnmatchedKeys = Self.unmatchedWatchedAssertionKeys(
            assertions: assertions, patterns: patterns, hits: matched,
        )
        for key in lastUnmatchedKeys {
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
