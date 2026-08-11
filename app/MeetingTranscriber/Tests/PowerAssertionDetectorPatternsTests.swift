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
            .patterns(watching: ["Microsoft Teams", "Zoom", "Webex", AppMeetingPattern.browserMeetings.appName])
            .map(\.appName)
        XCTAssertEqual(Set(names), Set(PowerAssertionDetector.defaultPatterns.map(\.appName)))
    }

    // MARK: - Browser (Chrome / WebRTC) pattern — issue #503

    func testBrowserPatternIsOptInViaWatching() {
        // The browser pattern ships in defaults but is only watched when the
        // browser toggle adds the category token to watchApps — off by default,
        // so the native-only selection must not include it.
        XCTAssertFalse(
            PowerAssertionDetector.patterns(watching: ["Microsoft Teams", "Zoom", "Webex"])
                .map(\.appName).contains(AppMeetingPattern.browserMeetings.appName),
        )
        XCTAssertTrue(
            PowerAssertionDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName])
                .map(\.appName).contains(AppMeetingPattern.browserMeetings.appName),
        )
    }

    func testChromeWebRTCCallIsDetected() {
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName]),
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
            patterns: PowerAssertionDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName]),
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
            patterns: PowerAssertionDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName]),
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
    /// share one toggle but NOT one identity: each fork is carried as itself, so
    /// a Brave call is a "Brave Browser" meeting and never a Chrome one.
    func testChromiumFamilyWebRTCCallsAreDetected() {
        for process in ["Google Chrome", "Brave Browser", "Microsoft Edge", "Chromium", "Aside"] {
            let detector = PowerAssertionDetector(
                patterns: PowerAssertionDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName]),
                confirmationCount: 1,
            )
            detector.windowListProvider = { [] }
            detector.assertionProvider = {
                assertionDict(processName: process, assertName: "WebRTC has active PeerConnections")
            }
            let meeting = detector.checkOnce()
            XCTAssertEqual(
                meeting?.pattern.appName, process,
                "\(process): a WebRTC call must be carried under the browser that held it",
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
                patterns: PowerAssertionDetector.patterns(watching: [AppMeetingPattern.browserMeetings.appName]),
                confirmationCount: 1,
            )
            detector.windowListProvider = { [] }
            detector.assertionProvider = {
                assertionDict(processName: process, assertName: "Playing audio")
            }
            XCTAssertNil(detector.checkOnce(), "\(process): media playback must not be a meeting")
        }
    }

    func testBrowserCategoryOwnsNoProcessNames() {
        // This replaces a test that pinned the browser AssertionPattern's
        // processNames equal to the category's ownerNames, because the two
        // lists were hand-maintained copies of the same Chromium family and
        // drift between them was silent. There is now only one list: the title
        // comes from the process that actually asserted, so the category holds
        // no owner names at all and there is nothing left to drift. Pin the
        // emptiness, because a non-empty list here would silently restore the
        // leak where one fork supplies another fork's meeting title.
        XCTAssertTrue(AppMeetingPattern.browserMeetings.ownerNames.isEmpty)
        let browser = PowerAssertionDetector.defaultPatterns.first { pattern in
            pattern.appName == AppMeetingPattern.browserMeetings.appName
        }
        XCTAssertEqual(browser?.identity, .perProcess)
    }

    func testOneBrowserWithTwoCallsInOnePollCountsOnce() {
        // This used to pin two DIFFERENT browsers counting once between them,
        // because they shared a single browser identity. They no longer do: each
        // fork counts for itself (see PowerAssertionDetectorIdentityTests). What
        // the once-per-poll guard still has to do is stop ONE browser from
        // double-incrementing when it holds two WebRTC assertions in the same
        // poll, which a browser with two calls open does; otherwise it would
        // confirm in one poll instead of the required two.
        let detector = PowerAssertionDetector(
            patterns: PowerAssertionDetector.patterns(
                watching: [AppMeetingPattern.browserMeetings.appName],
            ),
            confirmationCount: 2,
        )
        detector.windowListProvider = { [] }
        detector.assertionProvider = {
            [
                10: [[
                    "Process Name": "Brave Browser",
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
        XCTAssertNil(detector.checkOnce(), "two assertions from one browser in one poll must count once")
        XCTAssertNotNil(detector.checkOnce(), "its counter reaches confirmation on the second poll")
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
