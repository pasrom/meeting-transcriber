@testable import MeetingTranscriber
import XCTest

private func assertionDict(processName: String, assertName: String) -> [Int32: [[String: Any]]] {
    [1: [[
        "Process Name": processName,
        "AssertName": assertName,
        "AssertType": "PreventUserIdleDisplaySleep",
    ]]]
}

/// Tests for `PowerAssertionDetector.patterns(watching:)` — the "Apps to Watch"
/// toggle filtering (`AppSettings.watchApps`) that `WatchingController`'s default
/// detector applies. Split out of `PowerAssertionDetectorTests` (which is at the
/// type_body_length cap) since this is a distinct concern.
final class PowerAssertionDetectorPatternsTests: XCTestCase {
    func testPatternsWatchingAllKeepsEveryPattern() {
        // Every user-facing app watched (natives + browser) → every default pattern.
        let names = PowerAssertionDetector
            .patterns(watching: ["Microsoft Teams", "Zoom", "Webex", "Google Chrome"])
            .map(\.appName)
        XCTAssertEqual(Set(names), Set(PowerAssertionDetector.defaultPatterns.map(\.appName)))
    }

    // MARK: - Browser (Chrome / WebRTC) pattern — issue #503

    func testBrowserPatternIsOptInViaWatching() {
        // The Chrome browser pattern ships in defaults but is only watched when
        // the browser toggle adds "Google Chrome" to watchApps — off by default,
        // so the native-only selection must not include it.
        XCTAssertFalse(
            PowerAssertionDetector.patterns(watching: ["Microsoft Teams", "Zoom", "Webex"])
                .map(\.appName).contains("Google Chrome"),
        )
        XCTAssertTrue(
            PowerAssertionDetector.patterns(watching: ["Google Chrome"])
                .map(\.appName).contains("Google Chrome"),
        )
    }

    func testChromeWebRTCCallIsDetected() {
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: ["Google Chrome"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            assertionDict(processName: "Google Chrome", assertName: "WebRTC has active PeerConnections")
        }
        let meeting = detector.checkOnce()
        XCTAssertEqual(meeting?.pattern.appName, "Google Chrome")
        XCTAssertTrue(
            meeting?.pattern.requiresRecordingConsent ?? false,
            "a detected browser meeting must carry the consent flag",
        )
    }

    func testChromeMediaPlaybackIsNotDetectedAsMeeting() {
        // A Chrome tab playing audio/video (e.g. YouTube) also holds a
        // display-sleep assertion, but its name has no WebRTC marker — the
        // keyword match must reject it so we don't prompt on every video.
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: ["Google Chrome"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            assertionDict(processName: "Google Chrome", assertName: "Playing audio")
        }
        XCTAssertNil(detector.checkOnce())
    }

    func testNonChromeWebRTCAssertionIsNotDetected() {
        // The pattern matches by exact process name; a non-Chromium process
        // (Firefox has its own assertion mechanism) holding a WebRTC-named
        // assertion must not fire the browser pattern.
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: ["Google Chrome"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            assertionDict(processName: "firefox", assertName: "WebRTC has active PeerConnections")
        }
        XCTAssertNil(detector.checkOnce())
    }

    // MARK: - Chromium-family browsers (Brave / Edge / Chromium / Aside) — issue #503 follow-up

    /// The browser pattern is not Chrome-specific: every Chromium fork holds the
    /// same "WebRTC has active PeerConnections" assertion (it lives in Chromium's
    /// content layer), so Brave/Edge/Chromium/Aside calls must detect identically. They
    /// share the single "Google Chrome" browser-meetings identity (one toggle),
    /// but the detected meeting is titled by the concrete browser so a Brave call
    /// is not mislabeled "Google Chrome Call".
    func testChromiumFamilyWebRTCCallsAreDetected() {
        for process in ["Google Chrome", "Brave Browser", "Microsoft Edge", "Chromium", "Aside"] {
            let detector = PowerAssertionDetector(
                patterns: PowerAssertionDetector.patterns(watching: ["Google Chrome"]),
                confirmationCount: 1,
            )
            detector.windowListProvider = { [] }
            detector.assertionProvider = {
                assertionDict(processName: process, assertName: "WebRTC has active PeerConnections")
            }
            let meeting = detector.checkOnce()
            XCTAssertEqual(
                meeting?.pattern.appName, "Google Chrome",
                "\(process): WebRTC call must fire under the shared browser identity",
            )
            XCTAssertTrue(
                meeting?.pattern.requiresRecordingConsent ?? false,
                "\(process): a detected browser meeting must carry the consent flag",
            )
            XCTAssertEqual(
                meeting?.windowTitle, "\(process) Call",
                "\(process): placeholder title must name the concrete browser, not Chrome",
            )
        }
    }

    func testChromiumFamilyMediaPlaybackIsNotDetected() {
        // The WebRTC keyword gate applies to every browser process: plain media
        // playback (no WebRTC in the assertion name) must not prompt.
        for process in ["Brave Browser", "Microsoft Edge", "Chromium", "Aside"] {
            let detector = PowerAssertionDetector(
                patterns: PowerAssertionDetector.patterns(watching: ["Google Chrome"]),
                confirmationCount: 1,
            )
            detector.windowListProvider = { [] }
            detector.assertionProvider = {
                assertionDict(processName: process, assertName: "Playing audio")
            }
            XCTAssertNil(detector.checkOnce(), "\(process): media playback must not be a meeting")
        }
    }

    func testBrowserProcessNamesMatchOwnerNames() {
        // The browser AssertionPattern's processNames (used for detection) and
        // chromeBrowser.ownerNames (used for the window-title lookup) are two
        // hand-maintained copies of the same Chromium family. A fork added to
        // one list only would detect without a title, or title without
        // detecting, silently. Pin them equal so drift fails here.
        let browser = PowerAssertionDetector.defaultPatterns.first { pattern in
            pattern.appName == AppMeetingPattern.chromeBrowser.appName
        }
        XCTAssertEqual(browser?.processNames, AppMeetingPattern.chromeBrowser.ownerNames)
    }

    func testTwoFamilyBrowsersInOnePollCountOnce() {
        // Two Chromium browsers each holding a WebRTC assertion in the same poll
        // share the one browser identity. The once-per-poll guard must count that
        // as a single hit, not double-increment toward confirmation — otherwise
        // the pair would confirm in one poll instead of the required two.
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: ["Google Chrome"]),
            confirmationCount: 2,
        )
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            [
                10: [[
                    "Process Name": "Google Chrome",
                    "AssertName": "WebRTC has active PeerConnections",
                    "AssertType": "PreventUserIdleDisplaySleep",
                ]],
                20: [[
                    "Process Name": "Brave Browser",
                    "AssertName": "WebRTC has active PeerConnections",
                    "AssertType": "PreventUserIdleDisplaySleep",
                ]],
            ]
        }
        XCTAssertNil(detector.checkOnce(), "two browsers in one poll must count once, not reach confirmation")
        XCTAssertNotNil(detector.checkOnce(), "the shared counter reaches confirmation on the second poll")
    }

    func testPatternsWatchingSubsetDropsUnselectedApps() {
        let names = PowerAssertionDetector.patterns(watching: ["Zoom"]).map(\.appName)
        XCTAssertTrue(names.contains("Zoom"))
        XCTAssertFalse(names.contains("Microsoft Teams"))
        XCTAssertFalse(names.contains("Webex"))
    }

    func testPatternsWatchingAlwaysKeepsSimulator() {
        // The e2e/test meeting-simulator hook is never user-toggleable, so it
        // survives even when no meeting app is selected.
        let simulator = AppMeetingPattern.simulator.appName
        XCTAssertEqual(PowerAssertionDetector.patterns(watching: []).map(\.appName), [simulator])
        XCTAssertTrue(
            PowerAssertionDetector.patterns(watching: ["Microsoft Teams"]).map(\.appName).contains(simulator),
        )
    }

    func testDetectorWithFilteredPatternsIgnoresUnwatchedApp() {
        // A detector built for "Zoom only" must not fire on a Teams call, but a
        // Zoom call still fires — the user-visible effect of unchecking Teams.
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: ["Zoom"]),
            confirmationCount: 1,
        )
        detector.windowListProvider = { [] }

        detector.assertionProvider = {
            assertionDict(processName: "MSTeams", assertName: "Microsoft Teams Call in progress")
        }
        XCTAssertNil(detector.checkOnce(), "a Teams call must not be detected when only Zoom is watched")

        detector.assertionProvider = {
            assertionDict(processName: "zoom.us", assertName: "zoom call")
        }
        XCTAssertNotNil(detector.checkOnce(), "a Zoom call must still be detected")
    }

    @MainActor
    func testDefaultDetectorReadsWatchAppToggles() throws {
        // Pins the WatchingController wiring: the default detector must read the
        // toggles. With Teams off and Zoom on, a Teams call is ignored and a
        // Zoom call fires.
        let suite = "WatchAppWiring-\(getpid())-\(UUID().uuidString)"
        let settings = try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
        settings.watchTeams = false
        settings.watchZoom = true
        settings.watchWebex = false

        let detector = try XCTUnwrap(
            WatchingController.defaultDetectors(settings: settings)
                .compactMap { $0 as? PowerAssertionDetector }.first,
        )
        detector.windowListProvider = { [] }

        // The default confirmationCount is 2, so a matched app fires on the
        // second poll; poll twice each so the assertions actually distinguish
        // "filtered out" (never fires) from "would fire".
        detector.assertionProvider = {
            assertionDict(processName: "MSTeams", assertName: "Microsoft Teams Call in progress")
        }
        _ = detector.checkOnce()
        XCTAssertNil(detector.checkOnce(), "Teams off → a Teams call must never fire, even after two polls")

        detector.assertionProvider = {
            assertionDict(processName: "zoom.us", assertName: "zoom call")
        }
        _ = detector.checkOnce()
        XCTAssertNotNil(detector.checkOnce(), "Zoom on → a Zoom call must fire")
    }

    @MainActor
    func testDefaultDetectorWiresBrowserToggle() throws {
        // End-to-end wiring (issue #503): the watchBrowserMeetings toggle must
        // flow through watchApps → patterns(watching:) → the default detector,
        // so a Chrome WebRTC call fires only when the toggle is on.
        func detector(browserOn: Bool) throws -> PowerAssertionDetector {
            let suite = "BrowserWatchWiring-\(browserOn)-\(getpid())-\(UUID().uuidString)"
            let settings = try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
            settings.watchBrowserMeetings = browserOn
            let d = try XCTUnwrap(
                WatchingController.defaultDetectors(settings: settings)
                    .compactMap { $0 as? PowerAssertionDetector }.first,
            )
            d.windowListProvider = { [] }
            d.assertionProvider = {
                assertionDict(processName: "Google Chrome", assertName: "WebRTC has active PeerConnections")
            }
            return d
        }

        let on = try detector(browserOn: true)
        _ = on.checkOnce()
        XCTAssertNotNil(on.checkOnce(), "browser toggle on → a Chrome WebRTC call must fire")

        let off = try detector(browserOn: false)
        _ = off.checkOnce()
        XCTAssertNil(off.checkOnce(), "browser toggle off → a Chrome WebRTC call must be ignored")
    }
}
