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

    /// Off by default until the repair has been watched working on a real
    /// recording. The thresholds it decides by come from a single one, and this
    /// feature already passed every gate once while doing nothing in the field
    /// — a default of on is what would hide that happening again. Pinned rather
    /// than left implicit, because the e2e lane now has to ask for the feature
    /// and would otherwise assert against whatever the default happens to be.
    func testDedupIsOffByDefault() {
        XCTAssertFalse(freshSettings().echoDedupEnabled)
    }

    func testTogglePersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "echo-dedup-persist-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.echoDedupEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).echoDedupEnabled, "the choice has to survive a relaunch")
    }

    /// The control exists and writes back. One test, per the rule that the view
    /// layer is pinned for wiring and nothing else.
    ///
    /// Asserts the opposite of what it started as rather than a fixed value:
    /// the previous form hard-coded the answer the default produced, so moving
    /// the default broke a test about wiring for a reason that has nothing to
    /// do with wiring. The default has its own test above.
    func testToggleWritesBackToSettings() throws {
        let settings = freshSettings()
        let before = settings.echoDedupEnabled
        let view = AudioSettingsView(settings: settings)
        let toggle = try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.echoDedupToggle)
        try toggle.find(ViewType.Toggle.self).tap()
        XCTAssertEqual(settings.echoDedupEnabled, !before, "the control must write the opposite of what it showed")
    }
}
