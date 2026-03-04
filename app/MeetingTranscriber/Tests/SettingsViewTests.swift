import ViewInspector
import XCTest

@testable import MeetingTranscriber

final class SettingsViewTests: XCTestCase {

    // MARK: - tokenStatusInfo (pure function)

    func testTokenStatusInfoHasToken() {
        let info = tokenStatusInfo(hasToken: true)
        XCTAssertEqual(info.icon, "checkmark.circle.fill")
        XCTAssertEqual(info.color, "green")
    }

    func testTokenStatusInfoNoToken() {
        let info = tokenStatusInfo(hasToken: false)
        XCTAssertEqual(info.icon, "exclamationmark.triangle.fill")
        XCTAssertEqual(info.color, "orange")
    }

    // MARK: - View rendering

    func testViewRendersWithDefaults() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings)
        XCTAssertNoThrow(try sut.inspect())
    }

    func testDiarizeToggleExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Speaker Diarization"))
    }

    // MARK: - Diarize section

    func testDiarizeEnabledShowsExpectedSpeakers() throws {
        let settings = AppSettings()
        settings.diarize = true
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Expected Speakers"))
    }

    func testDiarizeEnabledShowsTokenSection() throws {
        let settings = AppSettings()
        settings.diarize = true
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Save Token"))
    }

    func testDiarizeEnabledShowsClearButton() throws {
        let settings = AppSettings()
        settings.diarize = true
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(button: "Clear"))
    }

    func testDiarizeEnabledShowsGetTokenLink() throws {
        let settings = AppSettings()
        settings.diarize = true
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Get token"))
    }

    func testDiarizeDisabledHidesTokenSection() throws {
        let settings = AppSettings()
        settings.diarize = false
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Save Token"))
    }

    // MARK: - Recording section

    func testNoMicToggleExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "No Microphone (app audio only)"))
    }

    func testMicSectionShownWhenMicEnabled() throws {
        let settings = AppSettings()
        settings.noMic = false
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Mic Speaker Name"))
    }

    func testMicSectionHiddenWhenNoMic() throws {
        let settings = AppSettings()
        settings.noMic = true
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertThrowsError(try body.find(text: "Mic Speaker Name"))
    }

    // MARK: - Apps section

    func testAppsToWatchSection() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Microsoft Teams"))
        XCTAssertNoThrow(try body.find(text: "Zoom"))
        XCTAssertNoThrow(try body.find(text: "Webex"))
    }

    // MARK: - Recording fields

    func testPollIntervalFieldExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Poll Interval"))
    }

    func testGracePeriodFieldExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Grace Period"))
    }

    func testWhisperModelPickerExists() throws {
        let settings = AppSettings()
        let sut = SettingsView(settings: settings)
        let body = try sut.inspect()
        XCTAssertNoThrow(try body.find(text: "Whisper Model"))
    }
}
