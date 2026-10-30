import XCTest

/// `DefaultsSuite` unlinks plists in the account's real `~/Library/Preferences`
/// for names it reads back from manifests, so only a name shaped like one a test
/// minted may ever map to a file there. Anything else, a manifest damaged or
/// planted, must not be able to delete a real application's preferences.
final class DefaultsSuiteScratchNameTests: XCTestCase {
    func testScratchNamesMapToAFile() {
        let uuid = UUID().uuidString
        for name in [
            "AppSettingsTests-\(getpid())-\(uuid)",
            "GeneralSettingsCustomAppsTests.\(uuid)",
            "WatchingControllerFactory-\(getpid())",
            "WatchingControllerFactory-\(getpid())-\(uuid)",
            "AppSettingsTests-precedence-\(uuid)",
            "WatchSlackTests.\(getpid()).\(uuid)",
            "nemotron-diarizer-mode-\(getpid())-\(uuid)",
            "LegacyDefaultsMigrationTests-legacy-\(uuid)",
        ] {
            XCTAssertNotNil(DefaultsSuite.suiteFile(named: name), name)
        }
    }

    func testOtherNamesAreRefused() {
        for name in [
            "", ".GlobalPreferences", "com.meetingtranscriber.app", "MeetingTranscriber",
            "com.apple.finder", "WatchingControllerFactory-", "WatchingControllerFactory-12x",
            "x/\(UUID().uuidString)", "AppSettingsTests-\(UUID().uuidString)-suffix",
            // A UUID tail alone is shape, not scratch: a domain-like or bare name
            // ending in one is still refused.
            "com.meetingtranscriber.app.\(UUID().uuidString)", UUID().uuidString,
            "-\(UUID().uuidString)", ".GlobalPreferences-\(UUID().uuidString)",
        ] {
            XCTAssertNil(DefaultsSuite.suiteFile(named: name), name)
        }
    }
}
