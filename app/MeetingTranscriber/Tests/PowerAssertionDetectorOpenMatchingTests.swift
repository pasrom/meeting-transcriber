@testable import MeetingTranscriber
import XCTest

private let webRTC = "WebRTC has active PeerConnections"

/// A browser name that appears nowhere in Sources, so no allowlist
/// implementation can pass the tests below: the literal exists only here.
private let unknownBrowser = "Fjordfox"

private func assertionDict(processName: String, assertName: String) -> [Int32: [[String: Any]]] {
    [1: [[
        "Process Name": processName,
        "AssertName": assertName,
        "AssertType": "PreventUserIdleDisplaySleep",
    ]]]
}

private func browserDetector() -> PowerAssertionDetector {
    let detector = PowerAssertionDetector(
        patterns: PowerAssertionDetector.patterns(
            watching: [AppMeetingPattern.browserMeetings.appName],
        ),
        confirmationCount: 1,
    )
    detector.windowListProvider = { [] }
    return detector
}

private func browserPattern() throws -> PowerAssertionDetector.AssertionPattern {
    try XCTUnwrap(
        PowerAssertionDetector.defaultPatterns
            .first { $0.appName == AppMeetingPattern.browserMeetings.appName },
    )
}

/// Process-open browser matching: the WebRTC assertion name is the signal, and
/// the process holding it is no longer checked against a hard-coded list of
/// Chromium forks. Every fork therefore works without a release, which is what
/// this change is for.
final class PowerAssertionDetectorOpenMatchingTests: XCTestCase {
    private var claimed: Set<String> {
        PowerAssertionDetector.claimedProcesses(in: PowerAssertionDetector.defaultPatterns)
    }

    // MARK: - Open matching

    func testAnUnknownBrowserIsDetected() throws {
        // The whole point: a fork nobody has heard of holds the assertion and is
        // recognised. No allowlist implementation can pass this.
        let pattern = try browserPattern()
        XCTAssertTrue(pattern.processNames.isEmpty, "the browser pattern must accept any process")
        XCTAssertTrue(PowerAssertionDetector.matches(
            pattern: pattern,
            processName: unknownBrowser,
            assertName: webRTC,
            assertType: "PreventUserIdleDisplaySleep",
            claimed: claimed,
        ))
    }

    func testOpenMatchingStillRequiresTheWebRTCKeyword() throws {
        // Without this the open pattern would fire on every process that keeps
        // the display awake, starting with a video player.
        XCTAssertFalse(try PowerAssertionDetector.matches(
            pattern: browserPattern(),
            processName: unknownBrowser,
            assertName: "Playing audio",
            assertType: "PreventUserIdleDisplaySleep",
            claimed: claimed,
        ))
    }

    func testUnknownBrowserReachesTheConsentPromptThroughTheDetector() {
        // End to end through checkOnce, not just the pure matcher: an unknown
        // fork must arrive as a per-process identity that still requires consent.
        let detector = browserDetector()
        detector.assertionProvider = { assertionDict(processName: unknownBrowser, assertName: webRTC) }
        let meeting = detector.checkOnce()
        XCTAssertEqual(meeting?.pattern.appName, unknownBrowser)
        XCTAssertTrue(
            meeting?.pattern.requiresRecordingConsent ?? false,
            "an unknown process must never auto-record",
        )
    }

    // MARK: - Native clients keep their own pattern

    func testANativeClientIsNeverTakenForABrowser() throws {
        // Teams is Electron and plausibly holds the identical assertion during a
        // call. Without this it would fire twice: once under its own pattern
        // with auto-start, once as a browser meeting with a consent prompt.
        XCTAssertFalse(try PowerAssertionDetector.matches(
            pattern: browserPattern(),
            processName: "MSTeams",
            assertName: webRTC,
            assertType: "PreventUserIdleDisplaySleep",
            claimed: claimed,
        ))
    }

    func testTheExclusionHoldsForAppsTheUserSwitchedOff() throws {
        // The claimed set comes from ALL known patterns, not the watched subset.
        // Computed from the watched subset instead, turning the Teams toggle off
        // would resurrect Teams recording through the browser path, against the
        // user's explicit opt-out.
        let browserOnly = PowerAssertionDetector.patterns(
            watching: [AppMeetingPattern.browserMeetings.appName],
        )
        XCTAssertFalse(browserOnly.contains { $0.appName == "Microsoft Teams" })
        XCTAssertFalse(try PowerAssertionDetector.matches(
            pattern: browserPattern(),
            processName: "MSTeams",
            assertName: webRTC,
            assertType: "PreventUserIdleDisplaySleep",
            claimed: PowerAssertionDetector.claimedProcesses(in: PowerAssertionDetector.defaultPatterns),
        ))
    }

    // MARK: - Web meetings still work

    func testWebZoomTeamsAndWebexAreStillDetected() {
        // The exclusion is keyed on the PROCESS, not the service: a Zoom, Teams
        // or Webex meeting taken in a browser holds the assertion under the
        // browser, which no native pattern claims. An exclusion written against
        // the service instead would silently kill web meetings, which is most of
        // what this feature is for, and nothing else would notice.
        for browser in ["Google Chrome", "Brave Browser", unknownBrowser] {
            let detector = browserDetector()
            detector.assertionProvider = { assertionDict(processName: browser, assertName: webRTC) }
            XCTAssertEqual(
                detector.checkOnce()?.pattern.appName, browser,
                "\(browser): a web meeting must still be detected",
            )
        }
    }

    // MARK: - Firefox, deliberately flipped

    func testNonChromiumBrowserNowDetectsToo() throws {
        // This inverts a test that pinned "firefox" holding a WebRTC-named
        // assertion as NOT detected, which was true only because the allowlist
        // happened to exclude it. Matching is now by the assertion name, so any
        // process claiming an active PeerConnection is a candidate and the
        // consent prompt (with its "Never for this app" action) is the filter.
        XCTAssertTrue(try PowerAssertionDetector.matches(
            pattern: browserPattern(),
            processName: "firefox",
            assertName: webRTC,
            assertType: "PreventUserIdleDisplaySleep",
            claimed: claimed,
        ))
    }

    // MARK: - Diagnostic

    func testAnUnmatchedWebRTCAssertionIsReportedFromAnyProcess() throws {
        // The gap that made a wrong fork name invisible: the diagnostic only
        // reported processes that were already on the allowlist, so a process
        // that failed to match produced no log line at all.
        let keys = try PowerAssertionDetector.unmatchedWatchedAssertionKeys(
            assertions: assertionDict(processName: "MSTeams", assertName: webRTC),
            patterns: [browserPattern()],
            hits: [],
        )
        XCTAssertEqual(keys, ["MSTeams|\(webRTC)|PreventUserIdleDisplaySleep"])
    }

    func testAMatchedAssertionIsNotReported() throws {
        // Control: without it a diagnostic that reported everything would pass
        // the test above.
        let keys = try PowerAssertionDetector.unmatchedWatchedAssertionKeys(
            assertions: assertionDict(processName: unknownBrowser, assertName: webRTC),
            patterns: [browserPattern()],
            hits: [unknownBrowser],
        )
        XCTAssertEqual(keys, [])
    }

    func testAnAssertionWithoutTheKeywordIsNotReported() throws {
        // Second control: the diagnostic is about WebRTC assertions that did not
        // act, not about every assertion on the machine.
        let keys = try PowerAssertionDetector.unmatchedWatchedAssertionKeys(
            assertions: assertionDict(processName: unknownBrowser, assertName: "Playing audio"),
            patterns: [browserPattern()],
            hits: [],
        )
        XCTAssertEqual(keys, [])
    }
}
