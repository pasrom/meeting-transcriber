@testable import MeetingTranscriber
import XCTest

/// The overlay-visibility preference, kept in its own file rather than in
/// `AppSettingsTests`: that file sits at the `file_length` limit, and the
/// per-setting shape (`EchoDedupSettingTests`, `EchoCancellationSettingTests`)
/// is where a setting's own round trip belongs anyway.
///
/// The default is pinned in `AppSettingsTests.testDefaultValues` alongside
/// every other default, so what is left here is the write path. Without it a
/// wrong `forKey:` in the `didSet` reads back as the missing-key default and
/// the preference silently resets to on at every launch, which no other test
/// would catch.
final class LiveCaptionsOverlaySettingTests: XCTestCase {
    func testPersistsAcrossInstances() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: "live-captions-overlay-\(getpid())-\(UUID().uuidString)"),
        )
        let settings = AppSettings(defaults: defaults)
        settings.liveCaptionsOverlayEnabled = false
        XCTAssertEqual(defaults.object(forKey: "liveCaptionsOverlayEnabled") as? Bool, false)
        XCTAssertFalse(
            AppSettings(defaults: defaults).liveCaptionsOverlayEnabled,
            "the choice has to survive a relaunch",
        )
    }
}
