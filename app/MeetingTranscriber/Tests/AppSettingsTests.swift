import Foundation
@testable import MeetingTranscriber
import XCTest

final class AppSettingsTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        let keys = [
            "watchTeams", "watchZoom", "watchWebex",
            "pollInterval", "endGrace", "noMic", "micDeviceUID", "micName",
            "diarize", "numSpeakers", "transcriptionModel", "claudeBin",
            "vadEnabled", "vadThreshold",
            "protocolProvider", "openAIEndpoint", "openAIModel",
            "checkForUpdates", "includePreReleases",
        ]
        KeychainHelper.delete(key: "openAIAPIKey")
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        settings = AppSettings()
    }

    override func tearDown() {
        settings = nil
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
        XCTAssertTrue(settings.vadEnabled)
        XCTAssertEqual(settings.vadThreshold, 0.85)
        XCTAssertEqual(settings.transcriptionModel, "parakeet-tdt-0.6b-v2-coreml")
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

    func testVadThresholdClampedToMax() {
        settings.vadThreshold = 1.5
        XCTAssertEqual(settings.vadThreshold, 1.0)
    }

    func testVadThresholdClampedToMin() {
        settings.vadThreshold = -0.5
        XCTAssertEqual(settings.vadThreshold, 0.0)
    }

    func testVadThresholdAcceptsValidValue() {
        settings.vadThreshold = 0.7
        XCTAssertEqual(settings.vadThreshold, 0.7)
    }

    // MARK: - UserDefaults persistence

    func testPollIntervalSavedToDefaults() {
        settings.pollInterval = 7.0
        XCTAssertEqual(UserDefaults.standard.double(forKey: "pollInterval"), 7.0)
    }

    func testClampedValueSavedToDefaults() {
        settings.pollInterval = 0.5
        XCTAssertEqual(UserDefaults.standard.double(forKey: "pollInterval"), 1.0)
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
            XCTAssertEqual(UserDefaults.standard.string(forKey: "claudeBin"), "claude-work")
        }
    #endif

    // MARK: - Transcription Model

    func testTranscriptionModelSavedToDefaults() {
        settings.transcriptionModel = "parakeet-tdt-0.6b-v2-coreml"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "transcriptionModel"), "parakeet-tdt-0.6b-v2-coreml")
    }

    func testMicNameSavedToDefaults() {
        settings.micName = "Roman"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "micName"), "Roman")
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
            UserDefaults.standard.string(forKey: "protocolProvider"),
            "openAICompatible",
        )
        // Verify a fresh instance reads it back
        let fresh = AppSettings()
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
            UserDefaults.standard.string(forKey: "openAIEndpoint"),
            "http://localhost:8080/v1/chat/completions",
        )
    }

    func testOpenAIModelSavedToDefaults() {
        settings.openAIModel = "mistral"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "openAIModel"), "mistral")
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
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "checkForUpdates"))
    }

    func testIncludePreReleasesPersistence() {
        settings.includePreReleases = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "includePreReleases"))
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
