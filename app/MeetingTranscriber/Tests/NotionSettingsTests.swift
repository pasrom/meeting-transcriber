import Foundation
@testable import MeetingTranscriber
import XCTest

final class NotionSettingsTests: XCTestCase {
    func testNotionSettingsPersistence() {
        let suite = "NotionSettingsTests-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(suite) }
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create test UserDefaults suite")
        }
        let notionKeyAccount = "notionKey.\(UUID().uuidString)"
        defer {
            KeychainHelper.delete(key: notionKeyAccount)
        }

        let settings = AppSettings(
            defaults: defaults,
            notionAPIKeyAccount: notionKeyAccount,
        )

        XCTAssertFalse(settings.notionExportEnabled)
        XCTAssertFalse(settings.notionSkipLocalMarkdownOnSuccess)
        XCTAssertFalse(settings.notionSpeakerTagsEnabled)
        XCTAssertEqual(settings.notionDatabaseID, "")
        XCTAssertEqual(settings.notionAPIKey, "")

        // Mutate settings
        settings.notionExportEnabled = true
        settings.notionSkipLocalMarkdownOnSuccess = true
        settings.notionSpeakerTagsEnabled = true
        settings.notionDatabaseID = "c83b8b171234456789abcdef01234567"
        settings.notionAPIKey = "ntn_mock_secret_token"

        // Verify values
        XCTAssertTrue(settings.notionExportEnabled)
        XCTAssertTrue(settings.notionSkipLocalMarkdownOnSuccess)
        XCTAssertTrue(settings.notionSpeakerTagsEnabled)
        XCTAssertEqual(settings.notionDatabaseID, "c83b8b171234456789abcdef01234567")
        XCTAssertEqual(settings.notionAPIKey, "ntn_mock_secret_token")

        // Reload fresh settings instance with same suite
        let reloaded = AppSettings(
            defaults: defaults,
            notionAPIKeyAccount: notionKeyAccount,
        )
        XCTAssertTrue(reloaded.notionExportEnabled)
        XCTAssertTrue(reloaded.notionSkipLocalMarkdownOnSuccess)
        XCTAssertTrue(reloaded.notionSpeakerTagsEnabled)
        XCTAssertEqual(reloaded.notionDatabaseID, "c83b8b171234456789abcdef01234567")
        XCTAssertEqual(reloaded.notionAPIKey, "ntn_mock_secret_token")
    }
}
