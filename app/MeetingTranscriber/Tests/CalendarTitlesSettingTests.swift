@testable import MeetingTranscriber
import XCTest

/// The calendar-titles preference's write path, in its own file for the same
/// reason as `LiveCaptionsOverlaySettingTests`: `AppSettingsTests` pins only
/// the default.
final class CalendarTitlesSettingTests: XCTestCase {
    func testPersistsAcrossInstances() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "calendar-titles-\(getpid())-\(UUID().uuidString)"),
        )
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.calendarTitlesEnabled, "opt-in: it asks for a Calendar permission")

        settings.calendarTitlesEnabled = true

        XCTAssertEqual(defaults.object(forKey: "calendarTitlesEnabled") as? Bool, true)
        XCTAssertTrue(
            AppSettings(defaults: defaults).calendarTitlesEnabled,
            "the choice has to survive a relaunch",
        )
    }
}
