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
        // All toggles on (the default) → every default pattern, unchanged.
        let names = PowerAssertionDetector
            .patterns(watching: ["Microsoft Teams", "Zoom", "Webex"])
            .map(\.appName)
        XCTAssertEqual(Set(names), Set(PowerAssertionDetector.defaultPatterns.map(\.appName)))
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
            WatchingController.defaultDetector(settings: settings) as? PowerAssertionDetector,
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
}
