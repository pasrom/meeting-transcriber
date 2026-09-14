@testable import MeetingTranscriber
import XCTest

/// The caption-size preference's write and read path, in its own file for the
/// same reason as `LiveCaptionsOverlaySettingTests`: `AppSettingsTests` sits at
/// the `file_length` limit and pins only the default.
final class LiveCaptionsSizeSettingTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "live-captions-size-\(getpid())-\(UUID().uuidString)"))
    }

    func testPersistsAcrossInstances() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.liveCaptionsSize = .small

        XCTAssertEqual(defaults.string(forKey: "liveCaptionsSize"), "small")
        XCTAssertEqual(
            AppSettings(defaults: defaults).liveCaptionsSize, .small,
            "the choice has to survive a relaunch",
        )
    }

    /// A stored value this build does not know (a preset removed later, or a
    /// hand-edited plist) must read as the default rather than crash or clear
    /// the rest of the settings.
    func testUnknownStoredValueReadsAsMedium() throws {
        let defaults = try makeDefaults()
        defaults.set("gigantic", forKey: "liveCaptionsSize")

        XCTAssertEqual(AppSettings(defaults: defaults).liveCaptionsSize, .medium)
    }
}
