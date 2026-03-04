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
}
