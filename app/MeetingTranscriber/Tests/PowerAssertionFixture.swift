@testable import MeetingTranscriber
import XCTest

/// Shared fixtures for the power-assertion detector suites.
///
/// Extracted because the assertion-dictionary shape was hand-maintained in
/// three test files, which is the same two-copies-drift failure mode this
/// feature just removed from production.
enum PowerAssertionFixture {
    static let webRTC = "WebRTC has active PeerConnections"

    /// A browser name that appears nowhere in Sources, so no allowlist
    /// implementation can pass a test that uses it.
    static let unknownBrowser = "Fjordfox"

    /// Assertions from one or more processes in a single poll. Variadic so a
    /// test can pin which browser a shared-keying implementation would have
    /// picked arbitrarily.
    static func assertions(
        _ entries: (pid: Int32, processName: String, assertName: String)...,
    ) -> [Int32: [[String: Any]]] {
        var out: [Int32: [[String: Any]]] = [:]
        for entry in entries {
            out[entry.pid] = [[
                "Process Name": entry.processName,
                "AssertName": entry.assertName,
                "AssertType": "PreventUserIdleDisplaySleep",
            ]]
        }
        return out
    }

    static func assertionDict(processName: String, assertName: String) -> [Int32: [[String: Any]]] {
        assertions((1, processName, assertName))
    }

    /// A detector watching only the browser category, with the window list
    /// stubbed empty so a test opts in to titles explicitly.
    static func browserDetector(confirmationCount: Int = 1) -> PowerAssertionDetector {
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(
                watching: [AppMeetingPattern.browserMeetings.appName],
            ),
            confirmationCount: confirmationCount,
        )
        detector.windowListProvider = { [] }
        return detector
    }

    static func browserPattern() throws -> PowerAssertionDetector.AssertionPattern {
        try XCTUnwrap(
            PowerAssertionDetector.defaultPatterns
                .first { $0.appName == AppMeetingPattern.browserMeetings.appName },
        )
    }
}
