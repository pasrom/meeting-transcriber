@testable import MeetingTranscriber
import XCTest

/// Assertions from several processes in one poll, so a test can pin which
/// browser a shared-keying implementation would have picked arbitrarily.
private func assertions(_ entries: (pid: Int32, processName: String, assertName: String)...)
    -> [Int32: [[String: Any]]] {
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

private let webRTC = "WebRTC has active PeerConnections"

private func browserDetector(confirmationCount: Int = 1) -> PowerAssertionDetector {
    let detector = PowerAssertionDetector(
        patterns: PowerAssertionDetector.patterns(
            watching: [AppMeetingPattern.browserMeetings.appName],
        ),
        confirmationCount: confirmationCount,
    )
    detector.windowListProvider = { [] }
    return detector
}

/// Per-process browser identity: every Chromium fork is carried as itself
/// rather than aliased into one shared browser identity. The forks used here
/// are all on the current allowlist on purpose, so these tests pin the
/// identity change alone and stay independent of process-open matching.
final class PowerAssertionDetectorIdentityTests: XCTestCase {
    // MARK: - Identity key

    func testSharedPatternIdentityKeyIsTheAppNameForAnyProcess() {
        // A native pattern is unaffected: whichever of its process names
        // asserted, the identity stays the one app.
        let teams = PowerAssertionDetector.defaultPatterns.first { $0.appName == "Microsoft Teams" }
        XCTAssertEqual(teams?.identity, .shared)
        XCTAssertEqual(teams?.identityKey(processName: "MSTeams"), "Microsoft Teams")
        XCTAssertEqual(teams?.identityKey(processName: "Microsoft Teams"), "Microsoft Teams")
    }

    func testPerProcessPatternIdentityKeyIsTheConcreteProcess() {
        // The browser pattern carries each fork as itself, which is what gives
        // every browser its own confirmation count, cooldown and tap target.
        let browser = PowerAssertionDetector.defaultPatterns
            .first { $0.appName == AppMeetingPattern.browserMeetings.appName }
        XCTAssertEqual(browser?.identity, .perProcess)
        XCTAssertEqual(browser?.identityKey(processName: "Brave Browser"), "Brave Browser")
        XCTAssertEqual(browser?.identityKey(processName: "Microsoft Edge"), "Microsoft Edge")
    }

    // MARK: - Synthesised identity

    func testPerProcessIdentityKeepsTheConsentRequirement() throws {
        // The trap this test exists for: with per-process identity,
        // `forAppName("Brave Browser")` no longer resolves, so the identity is
        // synthesised. The synthesis default for `requiresRecordingConsent` is
        // false, which would auto-record a browser call with no prompt.
        let browser = try XCTUnwrap(
            PowerAssertionDetector.defaultPatterns
                .first { $0.appName == AppMeetingPattern.browserMeetings.appName },
        )
        let identity = PowerAssertionDetector.meetingIdentity(
            pattern: browser, processName: "Brave Browser",
        )
        XCTAssertEqual(identity.appName, "Brave Browser")
        XCTAssertEqual(identity.ownerNames, ["Brave Browser"])
        XCTAssertTrue(identity.requiresRecordingConsent)
        // No title patterns: a browser window title reflects the active tab.
        XCTAssertTrue(identity.meetingPatterns.isEmpty)
    }

    func testSharedIdentityStillResolvesTheKnownAppPattern() throws {
        let teams = try XCTUnwrap(
            PowerAssertionDetector.defaultPatterns.first { $0.appName == "Microsoft Teams" },
        )
        let identity = PowerAssertionDetector.meetingIdentity(
            pattern: teams, processName: "MSTeams",
        )
        XCTAssertEqual(identity.appName, "Microsoft Teams")
    }

    // MARK: - Detector behaviour

    func testConfirmationCountsAreCountedPerBrowser() {
        // Poll 1: only Brave. Poll 2: Brave and Edge. With a shared key, poll 2
        // would be the shared key's second hit and `firstMatch` could be either
        // browser; per-process, only Brave has reached two polls.
        let detector = browserDetector(confirmationCount: 2)
        detector.assertionProvider = { assertions((7, "Brave Browser", webRTC)) }
        XCTAssertNil(detector.checkOnce())

        detector.assertionProvider = {
            assertions((7, "Brave Browser", webRTC), (9, "Microsoft Edge", webRTC))
        }
        let meeting = detector.checkOnce()
        XCTAssertEqual(meeting?.pattern.appName, "Brave Browser")
        XCTAssertEqual(meeting?.ownerName, "Brave Browser")
        XCTAssertEqual(meeting?.windowPID, 7)
    }

    func testLivenessFollowsTheBrowserThatHeldTheMeeting() throws {
        let detector = browserDetector()
        detector.assertionProvider = { assertions((7, "Brave Browser", webRTC)) }
        let meeting = try XCTUnwrap(detector.checkOnce())

        // Another fork's call must not keep this recording alive: that is what
        // ran a finished meeting to the four hour cap.
        detector.assertionProvider = { assertions((9, "Microsoft Edge", webRTC)) }
        XCTAssertFalse(detector.isMeetingActive(meeting))

        // Its own call must, or every browser recording would stop at the grace
        // period instead.
        detector.assertionProvider = { assertions((7, "Brave Browser", webRTC)) }
        XCTAssertTrue(detector.isMeetingActive(meeting))
    }

    func testTitleComesFromTheDetectedBrowserOnly() {
        // With one shared identity the title matcher accepted any family
        // browser's window, leaking an unrelated tab title into the protocol
        // filename and the model prompt.
        let detector = browserDetector()
        detector.assertionProvider = { assertions((7, "Brave Browser", webRTC)) }
        detector.windowListProvider = {
            [
                ["kCGWindowOwnerName": "Microsoft Edge", "kCGWindowName": "Private Banking"],
                ["kCGWindowOwnerName": "Brave Browser", "kCGWindowName": "Weekly Sync"],
            ]
        }
        XCTAssertEqual(detector.checkOnce()?.windowTitle, "Weekly Sync")
    }
}
