#if !APPSTORE
    import Foundation
    @testable import MeetingTranscriber
    import XCTest

    /// `AppSettings.claudeAPIKey`: the user-supplied, explicit-opt-in key for
    /// the Claude CLI protocol generator (Settings → Protocol Generation). In
    /// its own file because `AppSettingsTests` sits at the 600-line cap; same
    /// per-test defaults suite and Keychain account convention as
    /// `AppSettingsOutputDirectoryTests` so `--parallel` runs never share
    /// state or touch a real credential.
    final class AppSettingsClaudeAPIKeyTests: XCTestCase {
        // swiftlint:disable implicitly_unwrapped_optional
        private var settings: AppSettings!
        private var defaults: UserDefaults!
        private var testSuiteName: String!
        private var apiKeyAccount: String!
        private var claudeAPIKeyAccount: String!
        // swiftlint:enable implicitly_unwrapped_optional

        override func setUp() {
            super.setUp()
            testSuiteName = "AppSettingsClaudeAPIKeyTests-\(getpid())-\(UUID().uuidString)"
            apiKeyAccount = "AppSettingsClaudeAPIKeyTests-openAIAPIKey-\(getpid())-\(UUID().uuidString)"
            claudeAPIKeyAccount = "AppSettingsClaudeAPIKeyTests-claudeAPIKey-\(getpid())-\(UUID().uuidString)"
            guard let suite = UserDefaults(suiteName: testSuiteName) else {
                XCTFail("Could not create test UserDefaults suite")
                return
            }
            defaults = suite
            settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount, claudeAPIKeyAccount: claudeAPIKeyAccount)
        }

        override func tearDown() {
            settings = nil
            defaults.removePersistentDomain(forName: testSuiteName)
            defaults = nil
            testSuiteName = nil
            KeychainHelper.delete(key: apiKeyAccount)
            apiKeyAccount = nil
            KeychainHelper.delete(key: claudeAPIKeyAccount)
            claudeAPIKeyAccount = nil
            super.tearDown()
        }

        func testClaudeAPIKeyViaKeychainHelper() {
            // Asserting through `claudeAPIKeyAccount` also proves AppSettings
            // honours the injection: were it to fall back to the hardcoded
            // production account, every read here would come back nil.
            XCTAssertEqual(settings.claudeAPIKey, "")

            settings.claudeAPIKey = "sk-ant-test-key"
            XCTAssertEqual(KeychainHelper.read(key: claudeAPIKeyAccount), "sk-ant-test-key")
            XCTAssertEqual(settings.claudeAPIKey, "sk-ant-test-key")

            settings.claudeAPIKey = ""
            XCTAssertNil(KeychainHelper.read(key: claudeAPIKeyAccount))
            XCTAssertEqual(settings.claudeAPIKey, "")
        }

        /// `claudeAPIKey` and `openAIAPIKey` are backed by distinct Keychain
        /// accounts — setting one must never be visible through the other.
        func testClaudeAPIKeyIsIndependentOfOpenAIAPIKey() {
            settings.claudeAPIKey = "sk-ant-test-key"
            XCTAssertEqual(settings.openAIAPIKey, "")

            settings.openAIAPIKey = "sk-openai-test-key"
            XCTAssertEqual(settings.claudeAPIKey, "sk-ant-test-key")
        }
    }
#endif
