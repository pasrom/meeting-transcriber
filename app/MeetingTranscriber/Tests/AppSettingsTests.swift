import Foundation
import XCTest

@testable import MeetingTranscriber

final class AppSettingsTests: XCTestCase {

    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        // Clean UserDefaults keys before each test
        let keys = [
            "watchTeams", "watchZoom", "watchWebex",
            "pollInterval", "endGrace", "noMic", "micDeviceUID", "micName",
            "whisperModel", "diarize", "numSpeakers", "transcriptionEngine",
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
        XCTAssertFalse(settings.diarize)
        XCTAssertEqual(settings.whisperModel, "large-v3-turbo-q5_0")
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
        settings.endGrace = 2.0
        XCTAssertEqual(settings.endGrace, 5.0)
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

    // MARK: - buildArguments

    func testBuildArgumentsDefaults() {
        // All defaults → only --watch
        let args = settings.buildArguments()
        XCTAssertEqual(args, ["--watch"])
    }

    func testBuildArgumentsCustomPollInterval() {
        settings.pollInterval = 5.0
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--poll-interval"))
        XCTAssertTrue(args.contains("5.0"))
    }

    func testBuildArgumentsNoMic() {
        settings.noMic = true
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--no-mic"))
    }

    func testBuildArgumentsMicNameDefault() {
        // Default "Me" → no --mic-name flag
        let args = settings.buildArguments()
        XCTAssertFalse(args.contains("--mic-name"))
    }

    func testBuildArgumentsMicNameCustom() {
        settings.micName = "Roman"
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--mic-name"))
        XCTAssertTrue(args.contains("Roman"))
    }

    func testBuildArgumentsMicNameEmpty() {
        settings.micName = ""
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--mic-name"))
        XCTAssertTrue(args.contains(""))
    }

    func testMicNameSavedToDefaults() {
        settings.micName = "Roman"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "micName"), "Roman")
    }

    func testBuildArgumentsDiarize() {
        settings.diarize = true
        settings.numSpeakers = 4
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--diarize"))
        XCTAssertTrue(args.contains("--speakers"))
        XCTAssertTrue(args.contains("4"))
    }

    func testBuildArgumentsSubsetApps() {
        settings.watchTeams = false
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--watch-apps"))
        XCTAssertTrue(args.contains("Zoom"))
        XCTAssertTrue(args.contains("Webex"))
        XCTAssertFalse(args.contains("Microsoft Teams"))
    }

    func testBuildArgumentsAllAppsOmitsFlag() {
        // All 3 apps enabled → no --watch-apps flag needed
        let args = settings.buildArguments()
        XCTAssertFalse(args.contains("--watch-apps"))
    }

    func testBuildArgumentsNoMicSuppressesMicDevice() {
        // When noMic=true, --mic-device should NOT appear even if UID is set
        settings.noMic = true
        settings.micDeviceUID = "BuiltInMicrophoneDevice"
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--no-mic"))
        XCTAssertFalse(args.contains("--mic-device"))
    }

    func testBuildArgumentsMicDeviceWithoutNoMic() {
        settings.noMic = false
        settings.micDeviceUID = "BuiltInMicrophoneDevice"
        let args = settings.buildArguments()
        XCTAssertFalse(args.contains("--no-mic"))
        XCTAssertTrue(args.contains("--mic-device"))
        XCTAssertTrue(args.contains("BuiltInMicrophoneDevice"))
    }

    func testBuildArgumentsEmptyMicDeviceOmitsFlag() {
        settings.noMic = false
        settings.micDeviceUID = ""
        let args = settings.buildArguments()
        XCTAssertFalse(args.contains("--mic-device"))
    }

    func testBuildArgumentsDiarizeFalseIgnoresNumSpeakers() {
        settings.diarize = false
        settings.numSpeakers = 4
        let args = settings.buildArguments()
        XCTAssertFalse(args.contains("--diarize"))
        XCTAssertFalse(args.contains("--speakers"))
        XCTAssertFalse(args.contains("4"))
    }

    func testBuildArgumentsDiarizeWithAutoDetect() {
        settings.diarize = true
        settings.numSpeakers = 0
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--diarize"))
        XCTAssertFalse(args.contains("--speakers"))
    }

    func testBuildArgumentsAllCustom() {
        settings.watchTeams = true
        settings.watchZoom = false
        settings.watchWebex = false
        settings.pollInterval = 10.0
        settings.endGrace = 30.0
        settings.noMic = false
        settings.micDeviceUID = "USB-Mic-42"
        settings.micName = "Roman"
        settings.whisperModel = "tiny"
        settings.diarize = true
        settings.numSpeakers = 3
        let args = settings.buildArguments()

        XCTAssertTrue(args.contains("--watch"))
        XCTAssertTrue(args.contains("--watch-apps"))
        XCTAssertTrue(args.contains("Microsoft Teams"))
        XCTAssertTrue(args.contains("--poll-interval"))
        XCTAssertTrue(args.contains("10.0"))
        XCTAssertTrue(args.contains("--end-grace"))
        XCTAssertTrue(args.contains("30.0"))
        XCTAssertTrue(args.contains("--mic-device"))
        XCTAssertTrue(args.contains("USB-Mic-42"))
        XCTAssertTrue(args.contains("--mic-name"))
        XCTAssertTrue(args.contains("Roman"))
        XCTAssertTrue(args.contains("--model"))
        XCTAssertTrue(args.contains("tiny"))
        XCTAssertTrue(args.contains("--diarize"))
        XCTAssertTrue(args.contains("--speakers"))
        XCTAssertTrue(args.contains("3"))
        XCTAssertFalse(args.contains("--no-mic"))
    }

    func testBuildArgumentsNoAppsOmitsWatchApps() {
        settings.watchTeams = false
        settings.watchZoom = false
        settings.watchWebex = false
        let args = settings.buildArguments()
        // 0 apps → no --watch-apps flag (empty list)
        XCTAssertFalse(args.contains("--watch-apps"))
    }

    func testBuildArgumentsCustomWhisperModel() {
        settings.whisperModel = "small"
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--model"))
        XCTAssertTrue(args.contains("small"))
    }

    func testBuildArgumentsCustomEndGrace() {
        settings.endGrace = 60.0
        let args = settings.buildArguments()
        XCTAssertTrue(args.contains("--end-grace"))
        XCTAssertTrue(args.contains("60.0"))
    }

    // MARK: - HF Token (Keychain)

    func testKeychainRoundTrip() {
        // Clean up from any previous test run
        KeychainHelper.delete(key: "HF_TOKEN_TEST")

        // Initially empty
        XCTAssertFalse(KeychainHelper.exists(key: "HF_TOKEN_TEST"))
        XCTAssertNil(KeychainHelper.read(key: "HF_TOKEN_TEST"))

        // Save
        KeychainHelper.save(key: "HF_TOKEN_TEST", value: "hf_abc123")
        XCTAssertTrue(KeychainHelper.exists(key: "HF_TOKEN_TEST"))
        XCTAssertEqual(KeychainHelper.read(key: "HF_TOKEN_TEST"), "hf_abc123")

        // Overwrite
        KeychainHelper.save(key: "HF_TOKEN_TEST", value: "hf_xyz789")
        XCTAssertEqual(KeychainHelper.read(key: "HF_TOKEN_TEST"), "hf_xyz789")

        // Delete
        KeychainHelper.delete(key: "HF_TOKEN_TEST")
        XCTAssertFalse(KeychainHelper.exists(key: "HF_TOKEN_TEST"))
        XCTAssertNil(KeychainHelper.read(key: "HF_TOKEN_TEST"))
    }

    func testSetHFTokenStoresInKeychain() {
        settings.setHFToken("hf_test_token")
        XCTAssertTrue(settings.hasHFToken)
        XCTAssertEqual(settings.hfToken, "hf_test_token")

        // Clean up
        settings.setHFToken("")
        XCTAssertFalse(settings.hasHFToken)
        XCTAssertNil(settings.hfToken)
    }

    func testSetHFTokenTrimsWhitespace() {
        settings.setHFToken("  hf_trimmed  \n")
        XCTAssertEqual(settings.hfToken, "hf_trimmed")

        // Clean up
        settings.setHFToken("")
    }
}
