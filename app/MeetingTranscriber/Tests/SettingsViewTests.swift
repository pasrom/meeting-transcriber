@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class SettingsViewTests: XCTestCase {
    // MARK: - View rendering

    func testViewRendersWithDefaults() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        XCTAssertNoThrow(try sut.inspect())
    }

    func testDiarizeToggleExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Speaker Diarization"))
    }

    // MARK: - Diarize section

    func testDiarizeEnabledShowsExpectedSpeakers() throws {
        let settings = AppSettings()
        settings.diarize = true
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Expected Speakers"))
    }

    // MARK: - Recording section

    func testNoMicToggleExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "No Microphone (app audio only)"))
    }

    func testMicSectionShownWhenMicEnabled() throws {
        let settings = AppSettings()
        settings.noMic = false
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Mic Speaker Name"))
    }

    func testMicSectionHiddenWhenNoMic() throws {
        let settings = AppSettings()
        settings.noMic = true
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Mic Speaker Name"))
    }

    // MARK: - Apps section

    func testAppsToWatchSection() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Microsoft Teams"))
        XCTAssertNoThrow(try body.find(text: "Zoom"))
        XCTAssertNoThrow(try body.find(text: "Webex"))
    }

    // MARK: - Recording fields

    func testPollIntervalFieldExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Poll Interval"))
    }

    func testGracePeriodFieldExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Grace Period"))
    }

    func testWhisperKitModelPickerExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Model"))
    }

    // MARK: - Protocol Provider

    func testProviderPickerExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Provider"))
    }

    #if !APPSTORE
        func testClaudeCLIProviderShowsBinaryPicker() throws {
            let settings = AppSettings()
            settings.protocolProvider = .claudeCLI
            let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
            let body = try sut.inspect()
            XCTAssertNoThrow(try body.find(text: "Claude CLI"))
        }
    #endif

    func testOpenAIProviderShowsEndpointField() throws {
        let settings = AppSettings()
        settings.protocolProvider = .openAICompatible
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Endpoint"))
        XCTAssertNoThrow(try body.find(text: "API Key"))
        XCTAssertNoThrow(try body.find(text: "Fetch Models"))
    }

    // MARK: - Updates section

    func testUpdatesSectionShownWhenCheckerProvided() throws {
        let settings = AppSettings()
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let sut = SettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            updateChecker: checker,
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Check for Updates"))
        XCTAssertNoThrow(try body.find(text: "Check Now"))
    }

    func testUpdatesSectionHiddenWhenNoChecker() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings, whisperKitEngine: WhisperKitEngine(), parakeetEngine: ParakeetEngine())
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Check Now"))
    }

    func testPreReleaseToggleShownWhenCheckEnabled() throws {
        let settings = AppSettings()
        settings.checkForUpdates = true
        let checker = UpdateChecker(provider: MockUpdateProvider())
        let sut = SettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
            updateChecker: checker,
        )
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Include Pre-Releases"))
    }
}
