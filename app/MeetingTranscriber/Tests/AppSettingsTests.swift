import Foundation
import XCTest

@testable import MeetingTranscriber

final class AppSettingsTests: XCTestCase {

    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        let keys = [
            "watchTeams", "watchZoom", "watchWebex",
            "pollInterval", "endGrace", "noMic", "micDeviceUID", "micName",
            "diarize", "numSpeakers", "whisperKitModel",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        settings = AppSettings()
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

    // MARK: - WhisperKit Model

    func testWhisperKitModelSavedToDefaults() {
        settings.whisperKitModel = "openai_whisper-small"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "whisperKitModel"), "openai_whisper-small")
    }

    func testMicNameSavedToDefaults() {
        settings.micName = "Roman"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "micName"), "Roman")
    }

    // MARK: - HF Token (Keychain)

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

    func testSetHFTokenStoresInKeychain() {
        settings.setHFToken("hf_test_token")
        XCTAssertTrue(settings.hasHFToken)
        XCTAssertEqual(settings.hfToken, "hf_test_token")

        settings.setHFToken("")
        XCTAssertFalse(settings.hasHFToken)
        XCTAssertNil(settings.hfToken)
    }

    func testSetHFTokenTrimsWhitespace() {
        settings.setHFToken("  hf_trimmed  \n")
        XCTAssertEqual(settings.hfToken, "hf_trimmed")

        settings.setHFToken("")
    }
}
