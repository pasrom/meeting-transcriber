@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class WatchDiscordTests: XCTestCase {
    func testDiscordToggleOptsIntoMicDetectionAndTapsTheMainApp() throws {
        let settings = try makeIsolatedSettings()
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)
        XCTAssertFalse(settings.watchDiscord)
        XCTAssertFalse(settings.watchApps.contains("Discord"))

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.watchDiscordToggle)
            .find(ViewType.Toggle.self)
            .tap()

        XCTAssertTrue(settings.watchDiscord)
        let detector = MicInputDetector(patterns: MicInputDetector.patterns(watching: settings.watchApps), confirmationCount: 1)
        detector.mainAppPIDProvider = { $0 == "com.hnc.Discord" ? 100 : nil }
        detector.windowListProvider = { [] }
        detector.processProvider = {
            [.init(bundleID: "com.hnc.Discord.helper.Renderer", pid: 200, isRunningInput: true)]
        }

        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "Discord")
        XCTAssertEqual(meeting.windowPID, 100)
        XCTAssertTrue(detector.isMeetingActive(meeting))
    }

    func testWatchDiscordSurvivesReloadingSettings() throws {
        let suite = "WatchDiscordTests.\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        let settings = AppSettings(defaults: defaults)
        settings.watchDiscord = true
        XCTAssertTrue(AppSettings(defaults: defaults).watchDiscord)
    }

    func testDiscordMainProcessCannotBypassOptInThroughBrowserDetection() throws {
        let settings = try makeIsolatedSettings()
        settings.watchBrowserMeetings = true
        XCTAssertFalse(settings.watchDiscord)
        let browserPattern = try XCTUnwrap(PowerAssertionDetector.defaultPatterns.first(where: \.processNames.isEmpty))

        XCTAssertFalse(PowerAssertionDetector.matches(
            pattern: browserPattern, processName: "Discord",
            assertName: "WebRTC has active PeerConnections", assertType: "NoIdleSleepAssertion",
        ))
        XCTAssertTrue(PowerAssertionDetector.matches(
            pattern: browserPattern, processName: "Google Chrome",
            assertName: "WebRTC has active PeerConnections", assertType: "NoIdleSleepAssertion",
        ))
    }
}
