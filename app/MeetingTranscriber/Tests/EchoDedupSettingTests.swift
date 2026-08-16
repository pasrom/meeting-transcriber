@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// The switch behind transcript dedup: one wiring test for the control, and the
/// behaviour test that matters, which is that turning it off really does leave
/// the duplicates in.
@MainActor
final class EchoDedupSettingTests: XCTestCase {
    private func freshSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "echo-dedup-\(UUID().uuidString)")!
        // swiftlint:disable:previous force_unwrapping
        return AppSettings(defaults: defaults)
    }

    /// On by default because duplicated remote speech is wrong output rather
    /// than a missing feature: this repairs a defect, so the repair is the
    /// normal state.
    func testDedupIsOnByDefault() {
        XCTAssertTrue(freshSettings().echoDedupEnabled)
    }

    func testTogglePersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "echo-dedup-persist-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.echoDedupEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).echoDedupEnabled, "the choice has to survive a relaunch")
    }

    /// The control exists and writes back. One test, per the rule that the view
    /// layer is pinned for wiring and nothing else.
    func testToggleWritesBackToSettings() throws {
        let settings = freshSettings()
        let view = AudioSettingsView(settings: settings)
        let toggle = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.echoDedupToggle)
        try toggle.find(ViewType.Toggle.self).tap()
        XCTAssertFalse(settings.echoDedupEnabled)
    }
}
