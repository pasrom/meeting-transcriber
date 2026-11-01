import XCTest

/// `DefaultsSuite` still unlinks plists in the account's real
/// `~/Library/Preferences` for names it reads back from the manifests earlier
/// runs left, and for the `WatchingControllerFactory-<pid>` files it finds there
/// by prefix. Both go through `suiteFile(named:)`, so only a name shaped like one
/// a test minted may ever map to a file there. Anything else, a manifest damaged
/// or planted, must not be able to delete a real application's preferences.
final class DefaultsSuiteScratchNameTests: XCTestCase {
    /// The property everything else rests on: CFPreferences takes an
    /// absolute-path suite name as the location of the domain's file. If a
    /// macOS release stopped doing that, suites would quietly go back to
    /// `~/Library/Preferences`, and this is the test that would say so.
    func testAnOpenedSuiteIsFiledInTheProcessFolder() throws {
        let name = "DefaultsSuiteScratchNameTests-\(getpid())-\(UUID().uuidString)"
        defer { DefaultsSuite.remove(name) }
        let defaults = try XCTUnwrap(DefaultsSuite.open(name))
        defaults.set(true, forKey: "probe")
        let persisted = UserDefaults().persistentDomain(forName: DefaultsSuite.domain(name))
        XCTAssertEqual(persisted?["probe"] as? Bool, true, "the domain reads back from outside the instance")

        // Flush through cfprefsd rather than wait on its lazy write. Synchronize
        // promises the daemon has the value, not that the file is on disk yet,
        // so a short bounded wait stays as a backstop.
        XCTAssertTrue(CFPreferencesAppSynchronize(DefaultsSuite.domain(name) as CFString))
        let file = DefaultsSuite.processDirectory.appendingPathComponent("\(name).plist").path
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: file), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file), file)
    }

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
