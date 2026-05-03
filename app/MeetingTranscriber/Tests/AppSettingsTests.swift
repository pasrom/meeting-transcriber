import Foundation
@testable import MeetingTranscriber
import XCTest

final class AppSettingsTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var testSuiteName: String!

    /// Each test gets its own volatile `UserDefaults(suiteName:)` so
    /// `swift test --parallel` doesn't race on the shared on-disk plist.
    /// AppSettings receives the suite via constructor injection.
    override func setUp() {
        super.setUp()
        testSuiteName = "AppSettingsTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        defaults = suite
        KeychainHelper.delete(key: "openAIAPIKey")
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        settings = nil
        defaults.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        testSuiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultValues() {
        XCTAssertEqual(settings.pollInterval, 3.0)
        XCTAssertEqual(settings.endGrace, 15.0)
        XCTAssertEqual(settings.numSpeakers, 0)
        XCTAssertTrue(settings.watchTeams)
        XCTAssertTrue(settings.watchZoom)
        XCTAssertTrue(settings.watchWebex)
        XCTAssertFalse(settings.noMic)
        XCTAssertEqual(settings.micName, "Me")
        XCTAssertTrue(settings.diarize)
        XCTAssertEqual(settings.whisperKitModel, "openai_whisper-large-v3-v20240930_turbo")
    }

    // MARK: - Clamping

    func testPollIntervalClampedToMinimum() {
        settings.pollInterval = 0.1
        XCTAssertEqual(settings.pollInterval, 1.0)
    }

    func testPollIntervalAcceptsValidValue() {
        settings.pollInterval = 5.0
        XCTAssertEqual(settings.pollInterval, 5.0)
    }

    func testPollIntervalBoundaryValue() {
        settings.pollInterval = 1.0
        XCTAssertEqual(settings.pollInterval, 1.0)
    }

    func testEndGraceClampedToMinimum() {
        settings.endGrace = 0.5
        XCTAssertEqual(settings.endGrace, 1.0)
    }

    func testEndGraceAcceptsValidValue() {
        settings.endGrace = 30.0
        XCTAssertEqual(settings.endGrace, 30.0)
    }

    func testEndGraceBoundaryValue() {
        settings.endGrace = 5.0
        XCTAssertEqual(settings.endGrace, 5.0)
    }

    func testNumSpeakersClampedToMinimum() {
        settings.numSpeakers = -1
        XCTAssertEqual(settings.numSpeakers, 0)
    }

    func testNumSpeakersClampedToMinimumZero() {
        settings.numSpeakers = 0
        XCTAssertEqual(settings.numSpeakers, 0)
    }

    func testNumSpeakersAcceptsValidValue() {
        settings.numSpeakers = 5
        XCTAssertEqual(settings.numSpeakers, 5)
    }

    // MARK: - UserDefaults persistence

    func testPollIntervalSavedToDefaults() {
        settings.pollInterval = 7.0
        XCTAssertEqual(defaults.double(forKey: "pollInterval"), 7.0)
    }

    func testClampedValueSavedToDefaults() {
        settings.pollInterval = 0.5
        XCTAssertEqual(defaults.double(forKey: "pollInterval"), 1.0)
    }

    // MARK: - watchApps

    func testWatchAppsAllEnabled() {
        XCTAssertEqual(settings.watchApps, ["Microsoft Teams", "Zoom", "Webex"])
    }

    func testWatchAppsSingleDisabled() {
        settings.watchZoom = false
        XCTAssertEqual(settings.watchApps, ["Microsoft Teams", "Webex"])
    }

    func testWatchAppsAllDisabled() {
        settings.watchTeams = false
        settings.watchZoom = false
        settings.watchWebex = false
        XCTAssertEqual(settings.watchApps, [])
    }

    // MARK: - Claude CLI

    #if !APPSTORE
        func testClaudeBinDefault() {
            XCTAssertEqual(settings.claudeBin, "claude")
        }

        func testClaudeBinSavedToDefaults() {
            settings.claudeBin = "claude-work"
            XCTAssertEqual(defaults.string(forKey: "claudeBin"), "claude-work")
        }
    #endif

    // MARK: - WhisperKit Model

    func testWhisperKitModelSavedToDefaults() {
        settings.whisperKitModel = "openai_whisper-small"
        XCTAssertEqual(defaults.string(forKey: "whisperKitModel"), "openai_whisper-small")
    }

    func testMicNameSavedToDefaults() {
        settings.micName = "Speaker A"
        XCTAssertEqual(defaults.string(forKey: "micName"), "Speaker A")
    }

    // MARK: - Protocol Provider

    func testProtocolProviderDefault() {
        #if APPSTORE
            XCTAssertEqual(settings.protocolProvider, .openAICompatible)
        #else
            XCTAssertEqual(settings.protocolProvider, .claudeCLI)
        #endif
    }

    func testProtocolProviderPersistence() {
        settings.protocolProvider = .openAICompatible
        XCTAssertEqual(
            defaults.string(forKey: "protocolProvider"),
            "openAICompatible",
        )
        // Verify a fresh instance reads it back from the same suite.
        let fresh = AppSettings(defaults: defaults)
        XCTAssertEqual(fresh.protocolProvider, .openAICompatible)
    }

    func testOpenAIEndpointDefault() {
        XCTAssertEqual(settings.openAIEndpoint, "http://localhost:11434/v1/chat/completions")
    }

    func testOpenAIModelDefault() {
        XCTAssertEqual(settings.openAIModel, "llama3.1")
    }

    func testOpenAIAPIKeyViaKeychainHelper() {
        XCTAssertEqual(settings.openAIAPIKey, "")

        settings.openAIAPIKey = "sk-test-key"
        XCTAssertEqual(KeychainHelper.read(key: "openAIAPIKey"), "sk-test-key")
        XCTAssertEqual(settings.openAIAPIKey, "sk-test-key")

        settings.openAIAPIKey = ""
        XCTAssertNil(KeychainHelper.read(key: "openAIAPIKey"))
        XCTAssertEqual(settings.openAIAPIKey, "")
    }

    func testOpenAIEndpointSavedToDefaults() {
        settings.openAIEndpoint = "http://localhost:8080/v1/chat/completions"
        XCTAssertEqual(
            defaults.string(forKey: "openAIEndpoint"),
            "http://localhost:8080/v1/chat/completions",
        )
    }

    func testOpenAIModelSavedToDefaults() {
        settings.openAIModel = "mistral"
        XCTAssertEqual(defaults.string(forKey: "openAIModel"), "mistral")
    }

    // MARK: - Update Settings

    func testCheckForUpdatesDefault() {
        XCTAssertTrue(settings.checkForUpdates)
    }

    func testIncludePreReleasesDefault() {
        XCTAssertFalse(settings.includePreReleases)
    }

    func testCheckForUpdatesPersistence() {
        settings.checkForUpdates = false
        XCTAssertFalse(defaults.bool(forKey: "checkForUpdates"))
    }

    func testIncludePreReleasesPersistence() {
        settings.includePreReleases = true
        XCTAssertTrue(defaults.bool(forKey: "includePreReleases"))
    }

    // MARK: - Keychain

    func testKeychainRoundTrip() {
        KeychainHelper.delete(key: "HF_TOKEN_TEST")

        XCTAssertFalse(KeychainHelper.exists(key: "HF_TOKEN_TEST"))
        XCTAssertNil(KeychainHelper.read(key: "HF_TOKEN_TEST"))

        KeychainHelper.save(key: "HF_TOKEN_TEST", value: "hf_abc123")
        XCTAssertTrue(KeychainHelper.exists(key: "HF_TOKEN_TEST"))
        XCTAssertEqual(KeychainHelper.read(key: "HF_TOKEN_TEST"), "hf_abc123")

        KeychainHelper.save(key: "HF_TOKEN_TEST", value: "hf_xyz789")
        XCTAssertEqual(KeychainHelper.read(key: "HF_TOKEN_TEST"), "hf_xyz789")

        KeychainHelper.delete(key: "HF_TOKEN_TEST")
        XCTAssertFalse(KeychainHelper.exists(key: "HF_TOKEN_TEST"))
        XCTAssertNil(KeychainHelper.read(key: "HF_TOKEN_TEST"))
    }
}
