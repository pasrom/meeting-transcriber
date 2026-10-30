@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The built-in Slack Huddles toggle (issue #608): opt-in mic-input detection
/// on Slack's Electron helpers, and its coexistence with a Slack entry the user
/// added under Apps to Watch before the toggle existed.
@MainActor
final class WatchSlackTests: XCTestCase {
    private let slackBundleID = "com.tinyspeck.slackmacgap"

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "WatchSlackTests.\(getpid()).\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suiteName) }
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func makeSettings() throws -> AppSettings {
        try AppSettings(defaults: makeDefaults())
    }

    private func snapshot(_ bundleID: String, pid: pid_t) -> MicInputDetector.AudioProcessSnapshot {
        MicInputDetector.AudioProcessSnapshot(bundleID: bundleID, pid: pid, isRunningInput: true)
    }

    // MARK: - Pattern selection

    func testSlackIsWatchedOnlyWhenSelected() {
        XCTAssertFalse(MicInputDetector.patterns(watching: []).contains { $0.appName == "Slack" })
        XCTAssertEqual(MicInputDetector.patterns(watching: ["Slack"]).map(\.appName), ["Slack"])
    }

    func testSlackPatternMatchesItsHelpersButNotLookalikes() throws {
        let slack = try XCTUnwrap(MicInputDetector.defaultPatterns.first { $0.appName == "Slack" })
        XCTAssertTrue(slack.matches(bundleID: slackBundleID))
        XCTAssertTrue(slack.matches(bundleID: "\(slackBundleID).helper"))
        XCTAssertTrue(slack.matches(bundleID: "\(slackBundleID).helper.Renderer"))
        XCTAssertFalse(slack.matches(bundleID: "\(slackBundleID)extra"))
        XCTAssertFalse(slack.matches(bundleID: "com.tinyspeck.other"))
    }

    func testSlackHelperHoldingTheMicIsDetectedAndTapsTheMainApp() throws {
        let detector = MicInputDetector(patterns: MicInputDetector.patterns(watching: ["Slack"]), confirmationCount: 1)
        detector.windowListProvider = { [] }
        detector.mainAppPIDProvider = { [slackBundleID] in $0 == slackBundleID ? 100 : nil }
        detector.processProvider = { [slackBundleID] in [self.snapshot("\(slackBundleID).helper", pid: 555)] }

        let meeting = try XCTUnwrap(detector.checkOnce())
        XCTAssertEqual(meeting.pattern.appName, "Slack")
        XCTAssertEqual(meeting.windowPID, 100, "a helper hit must tap the main app's process tree")
        XCTAssertEqual(meeting.windowTitle, PowerAssertionDetector.placeholderTitle(appName: "Slack"))
        XCTAssertTrue(detector.isMeetingActive(meeting))
    }

    // MARK: - Coexistence with a custom Slack entry

    func testCustomSlackEntryIsDroppedWhileTheToggleIsOn() {
        let patterns = MicInputDetector.patterns(
            watching: ["Slack"],
            customBundleIDs: [slackBundleID, "com.example.callapp"],
        )
        XCTAssertEqual(patterns.count, 2, "the built-in pattern plus the unrelated custom app, no second Slack")
        XCTAssertTrue(patterns[0].usesBuiltInMeetingPattern)
        XCTAssertEqual(patterns[1].bundleIDs, ["com.example.callapp"])
    }

    func testCustomSlackEntryStillWorksWhileTheToggleIsOff() {
        let patterns = MicInputDetector.patterns(watching: [], customBundleIDs: [slackBundleID])
        XCTAssertEqual(patterns.map(\.bundleIDs), [[slackBundleID]])
        XCTAssertFalse(patterns[0].usesBuiltInMeetingPattern)
    }

    func testAddingSlackAsACustomAppPointsAtTheToggle() {
        XCTAssertEqual(
            GeneralSettingsView.watchRefusal(name: "Slack", bundleID: slackBundleID, info: [:]),
            "Slack has its own toggle above.",
        )
        XCTAssertEqual(
            GeneralSettingsView.watchRefusal(name: "Slack Helper", bundleID: "\(slackBundleID).helper", info: [:]),
            "Slack has its own toggle above.",
            "a helper the toggle's pattern matches is refused by the same rule the detector dedups with",
        )
    }

    // MARK: - Settings

    func testWatchSlackDefaultsOffAndIsNotWatched() throws {
        let settings = try makeSettings()
        XCTAssertFalse(settings.watchSlack)
        XCTAssertFalse(settings.watchApps.contains("Slack"))
    }

    func testWatchSlackAppendsSlackToWatchAppsAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.watchSlack = true
        XCTAssertEqual(settings.watchApps.last, AppMeetingPattern.slack.appName)
        XCTAssertTrue(AppSettings(defaults: defaults).watchSlack)
    }

    func testSlackToggleWritesBackToSettings() throws {
        let settings = try makeSettings()
        let view = GeneralSettingsView(settings: settings, notificationVisibility: nil)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.watchSlackToggle)
            .find(ViewType.Toggle.self)
            .tap()

        XCTAssertTrue(settings.watchSlack)
    }
}
