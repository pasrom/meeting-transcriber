import Foundation
@testable import MeetingTranscriber
import XCTest

/// Flags written with an untyped `defaults write <domain> <key> 1` (issue #814).
/// That stores the STRING "1"; `object(forKey:) as? Bool` read it as missing
/// and fell back to the default, while the launch path's `bool(forKey:)` read
/// `autoWatch` as on, so the same input meant two different things.
final class AppSettingsUntypedDefaultsTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var apiKeyAccount: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsUntypedDefaultsTests-\(getpid())-\(UUID().uuidString)"
        apiKeyAccount = "AppSettingsUntypedDefaultsTests-openAIAPIKey-\(getpid())-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        KeychainHelper.delete(key: apiKeyAccount)
        apiKeyAccount = nil
        super.tearDown()
    }

    func testUntypedOneReadsAsTrue() {
        defaults.set("1", forKey: "watchBrowserMeetings")
        defaults.set("1", forKey: "autoWatch")
        let settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount)
        XCTAssertTrue(settings.watchBrowserMeetings)
        XCTAssertTrue(settings.autoWatch)
    }

    func testUnreadableValueKeepsTheDefault() {
        // `bool(forKey:)` would read "on" as false and switch a default-on
        // setting off; an unreadable value is not an answer.
        defaults.set("on", forKey: "watchTeams")
        defaults.set(Data([1]), forKey: "diarize")
        let settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount)
        XCTAssertTrue(settings.watchTeams)
        XCTAssertTrue(settings.diarize)
    }

    func testLegacyVerboseFlagSurvivesAnUnreadableNewKey() {
        defaults.set("garbage", forKey: "verboseDiagnostics")
        defaults.set(true, forKey: "audioDebugLogging")
        let settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount)
        XCTAssertTrue(settings.verboseDiagnostics)
    }

    func testMissingFlagStillReadsItsDefault() {
        // Control: coercion must not turn a missing key into false for a
        // default-on setting.
        XCTAssertTrue(defaults.bool(forKey: "watchTeams", default: true))
        XCTAssertFalse(defaults.bool(forKey: "watchTeams", default: false))
    }
}
