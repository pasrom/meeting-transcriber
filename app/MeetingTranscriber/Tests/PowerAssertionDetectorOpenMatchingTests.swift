@testable import MeetingTranscriber
import XCTest

/// Process-open browser matching: the WebRTC assertion name is the signal, and
/// the process holding it is no longer checked against a hard-coded list of
/// Chromium forks. Every fork therefore works without a release, which is what
/// this change is for.
final class PowerAssertionDetectorOpenMatchingTests: XCTestCase {
    // MARK: - Open matching

    func testAnUnknownBrowserIsDetected() throws {
        // The whole point: a fork nobody has heard of holds the assertion and is
        // recognised. No allowlist implementation can pass this.
        let pattern = try PowerAssertionFixture.browserPattern()
        XCTAssertTrue(pattern.processNames.isEmpty, "the browser pattern must accept any process")
        XCTAssertTrue(PowerAssertionDetector.matches(
            pattern: pattern,
            processName: PowerAssertionFixture.unknownBrowser,
            assertName: PowerAssertionFixture.webRTC,
            assertType: "PreventUserIdleDisplaySleep",
        ))
    }

    func testOpenMatchingStillRequiresTheWebRTCKeyword() throws {
        // Without this the open pattern would fire on every process that keeps
        // the display awake, starting with a video player.
        XCTAssertFalse(try PowerAssertionDetector.matches(
            pattern: PowerAssertionFixture.browserPattern(),
            processName: PowerAssertionFixture.unknownBrowser,
            assertName: "Playing audio",
            assertType: "PreventUserIdleDisplaySleep",
        ))
    }

    func testUnknownBrowserReachesTheConsentPromptThroughTheDetector() {
        // End to end through checkOnce, not just the pure matcher: an unknown
        // fork must arrive as a per-process identity that still requires consent.
        let detector = PowerAssertionFixture.browserDetector()
        detector.assertionProvider = {
            PowerAssertionFixture.assertionDict(processName: PowerAssertionFixture.unknownBrowser, assertName: PowerAssertionFixture.webRTC)
        }
        let meeting = detector.checkOnce()
        XCTAssertEqual(meeting?.pattern.appName, PowerAssertionFixture.unknownBrowser)
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
            pattern: PowerAssertionFixture.browserPattern(),
            processName: "MSTeams",
            assertName: PowerAssertionFixture.webRTC,
            assertType: "PreventUserIdleDisplaySleep",
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
            pattern: PowerAssertionFixture.browserPattern(),
            processName: "MSTeams",
            assertName: PowerAssertionFixture.webRTC,
            assertType: "PreventUserIdleDisplaySleep",
        ))
    }

    // MARK: - Web meetings still work

    func testWebZoomTeamsAndWebexAreStillDetected() {
        // The exclusion is keyed on the PROCESS, not the service: a Zoom, Teams
        // or Webex meeting taken in a browser holds the assertion under the
        // browser, which no native pattern claims. An exclusion written against
        // the service instead would silently kill web meetings, which is most of
        // what this feature is for, and nothing else would notice.
        for browser in ["Google Chrome", "Brave Browser", PowerAssertionFixture.unknownBrowser] {
            let detector = PowerAssertionFixture.browserDetector()
            detector.assertionProvider = { PowerAssertionFixture.assertionDict(processName: browser, assertName: PowerAssertionFixture.webRTC) }
            XCTAssertEqual(
                detector.checkOnce()?.pattern.appName, browser,
                "\(browser): a web meeting must still be detected",
            )
        }
    }

    func testABlankProcessNameIsRejected() throws {
        // The name becomes the identity, the prompt body and the deny-list key,
        // so a blank one would ask "A meeting is active in ." and leave a blank
        // row in Settings that matches nothing.
        XCTAssertFalse(try PowerAssertionDetector.matches(
            pattern: PowerAssertionFixture.browserPattern(),
            processName: "",
            assertName: PowerAssertionFixture.webRTC,
            assertType: "PreventUserIdleDisplaySleep",
        ))
        XCTAssertFalse(try PowerAssertionDetector.matches(
            pattern: PowerAssertionFixture.browserPattern(),
            processName: "   ",
            assertName: PowerAssertionFixture.webRTC,
            assertType: "PreventUserIdleDisplaySleep",
        ))
    }

    // MARK: - Firefox, deliberately flipped

    func testNonChromiumBrowserNowDetectsToo() throws {
        // This inverts a test that pinned "firefox" holding a WebRTC-named
        // assertion as NOT detected, which was true only because the allowlist
        // happened to exclude it. Matching is now by the assertion name, so any
        // process claiming an active PeerConnection is a candidate and the
        // consent prompt (with its "Never for this app" action) is the filter.
        XCTAssertTrue(try PowerAssertionDetector.matches(
            pattern: PowerAssertionFixture.browserPattern(),
            processName: "firefox",
            assertName: PowerAssertionFixture.webRTC,
            assertType: "PreventUserIdleDisplaySleep",
        ))
    }

    // MARK: - Diagnostic

    func testAnUnmatchedWebRTCAssertionIsReportedFromAnyProcess() throws {
        // The gap that made a wrong fork name invisible: the diagnostic only
        // reported processes that were already on the allowlist, so a process
        // that failed to match produced no log line at all.
        let keys = try PowerAssertionDetector.unmatchedWatchedAssertionKeys(
            assertions: PowerAssertionFixture.assertionDict(
                processName: PowerAssertionFixture.unknownBrowser,
                assertName: PowerAssertionFixture.webRTC,
            ),
            patterns: [PowerAssertionFixture.browserPattern()],
            hits: [],
        )
        XCTAssertEqual(
            keys,
            ["\(PowerAssertionFixture.unknownBrowser)|\(PowerAssertionFixture.webRTC)|PreventUserIdleDisplaySleep"],
        )
    }

    func testANativeClientsWebRTCAssertionIsNotReportedByTheOpenPattern() throws {
        // Teams is excluded from open matching by design and its own pattern
        // reports its own misses. Reporting it here made the log say "detection
        // is not firing" during a native call that was detected perfectly,
        // pointing a bug report at a failure that never happened.
        let keys = try PowerAssertionDetector.unmatchedWatchedAssertionKeys(
            assertions: PowerAssertionFixture.assertionDict(
                processName: "MSTeams", assertName: PowerAssertionFixture.webRTC,
            ),
            patterns: [PowerAssertionFixture.browserPattern()],
            hits: [],
        )
        XCTAssertEqual(keys, [])
    }

    func testAMatchedAssertionIsNotReported() throws {
        // Control: without it a diagnostic that reported everything would pass
        // the test above.
        let keys = try PowerAssertionDetector.unmatchedWatchedAssertionKeys(
            assertions: PowerAssertionFixture.assertionDict(processName: PowerAssertionFixture.unknownBrowser, assertName: PowerAssertionFixture.webRTC),
            patterns: [PowerAssertionFixture.browserPattern()],
            hits: [PowerAssertionFixture.unknownBrowser],
        )
        XCTAssertEqual(keys, [])
    }

    func testAnAssertionWithoutTheKeywordIsNotReported() throws {
        // Second control: the diagnostic is about WebRTC assertions that did not
        // act, not about every assertion on the machine.
        let keys = try PowerAssertionDetector.unmatchedWatchedAssertionKeys(
            assertions: PowerAssertionFixture.assertionDict(processName: PowerAssertionFixture.unknownBrowser, assertName: "Playing audio"),
            patterns: [PowerAssertionFixture.browserPattern()],
            hits: [],
        )
        XCTAssertEqual(keys, [])
    }
}
