import Foundation
@testable import MeetingTranscriber
import XCTest

final class AITitleFilenamesSettingTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var apiKeyAccount: String!

    /// An isolated suite and Keychain account, as in `AppSettingsTests`, so the test never
    /// touches the real defaults or the credential the installed app uses.
    override func setUp() {
        super.setUp()
        suiteName = "AITitleFilenamesSettingTests-\(getpid())-\(UUID().uuidString)"
        apiKeyAccount = "AITitleFilenamesSettingTests-openAIAPIKey-\(getpid())-\(UUID().uuidString)"
        defaults = DefaultsSuite.open(suiteName)
        settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount)
    }

    override func tearDown() {
        settings = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        KeychainHelper.delete(key: apiKeyAccount)
        apiKeyAccount = nil
        super.tearDown()
    }

    /// Off by default and persisted: turning it on renames every user's output
    /// files after the fact, so it has to be an explicit, remembered choice.
    func testUseAITitleForFilenamesDefaultsToOffAndPersists() {
        XCTAssertFalse(settings.useAITitleForFilenames)

        settings.useAITitleForFilenames = true
        XCTAssertEqual(defaults.object(forKey: "useAITitleForFilenames") as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount).useAITitleForFilenames)
    }
}
