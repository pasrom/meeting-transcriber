import Foundation

/// The "we saw something that looks like a meeting and did not act on it"
/// diagnostic, split out of `PowerAssertionDetector` to keep that file under the
/// length cap.
///
/// It exists because a detection gap is otherwise invisible from outside the
/// app: the assertion is there, nothing happens, and no log says why. It used to
/// be gated on the same process allowlist it was meant to diagnose, so a process
/// that failed to match produced no line at all, which is how a wrong browser
/// name could ship unnoticed.
extension PowerAssertionDetector {
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
                guard let processName = assertion["Process Name"] as? String,
                      // Cheap gate first: all but a handful of assertions on the
                      // machine belong to neither an open pattern's keywords nor
                      // a bound pattern's processes, and bridging the remaining
                      // fields out of `Any` for every one of them was the cost
                      // this scan used to avoid with its allowlist check.
                      couldInterest(patterns: patterns, processName: processName, assertion: assertion)
                else { continue }
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

    /// Cheap pre-gate for `unmatchedWatchedAssertionKeys`: can this process
    /// possibly interest ANY pattern? Bound patterns care only about their own
    /// processes; an open pattern cares about the assertion name, so it is only
    /// worth reading that name when an open pattern is present at all.
    private static func couldInterest(
        patterns: [AssertionPattern],
        processName: String,
        assertion: [String: Any],
    ) -> Bool {
        for pattern in patterns {
            if pattern.processNames.isEmpty {
                guard let assertName = assertion["AssertName"] as? String else { continue }
                if pattern.matchesKeyword(in: assertName) { return true }
            } else if pattern.processNames.contains(processName) {
                return true
            }
        }
        return false
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
            // A claimed process is excluded from open matching by design, and
            // its own bound pattern reports it if IT missed. Reporting it here
            // too fires "detection is not firing" during a native call that was
            // detected perfectly, which is worse than silence: it points a bug
            // report at a failure that did not happen.
            guard !claimedProcesses.contains(processName) else { return false }
            return pattern.matchesKeyword(in: assertName)
        }
        return pattern.processNames.contains(processName)
    }

    /// Log, once per distinct key, that a watched meeting app is running but its
    /// assertion matched nothing this round — the "detection silently not firing"
    /// signal from issue #446, previously visible only via manual pmset. The
    /// names are app/OS-generated metadata (no user content), logged `.public`
    /// so a reporter's diagnostic export names the actual assertion.
}
