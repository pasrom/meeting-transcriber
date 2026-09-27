@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The switch behind the opt-in silent-track watchdog (issue #672): off by
/// default, persisted, and wired to its toggle. Whether it reaches the capture
/// is pinned where the capture configuration is built.
@MainActor
final class SilentTrackWatchdogSettingTests: XCTestCase {
    private func freshSettings() -> AppSettings {
        let name = "silent-track-watchdog-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        // swiftlint:disable:previous force_unwrapping
        addTeardownBlock { DefaultsSuite.remove(name) }
        return AppSettings(defaults: defaults)
    }

    /// Off until a field log shows a rebuild restoring a tap that went silent.
    /// Each rebuild costs audio and is exposed to the restart wedge of issue
    /// #588, and a far end that is genuinely silent trips it too.
    func testTheWatchdogIsOffByDefault() {
        XCTAssertFalse(freshSettings().silentTrackWatchdogEnabled)
    }

    func testTheChoicePersists() throws {
        let name = "silent-track-watchdog-persist-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        AppSettings(defaults: defaults).silentTrackWatchdogEnabled = true
        XCTAssertTrue(
            AppSettings(defaults: defaults).silentTrackWatchdogEnabled,
            "the choice has to survive a relaunch",
        )
    }

    func testToggleWritesBackToSettings() throws {
        let settings = freshSettings()
        let before = settings.silentTrackWatchdogEnabled
        let view = AudioSettingsView(settings: settings)
        let toggle = try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.silentTrackWatchdogToggle)
        try toggle.find(ViewType.Toggle.self).tap()
        XCTAssertEqual(settings.silentTrackWatchdogEnabled, !before)
    }
}
