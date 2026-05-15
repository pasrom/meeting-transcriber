@testable import MeetingTranscriber
import XCTest

/// Regression guard for issue #256: the WhisperKit language picker must
/// expose languages that real users actually need (Polish was the bug
/// reporter's case). Without these picker options, a user speaking an
/// unlisted language is forced onto Auto-detect — which large-v3 is
/// documented to drift away from on under-represented languages,
/// producing the reported English output.
@MainActor
final class TranscriptionSettingsLanguagePickerTests: XCTestCase {
    private func codes() -> [String] {
        TranscriptionSettingsView.whisperLanguages.map(\.code)
    }

    func testIncludesAutoDetect() {
        XCTAssertTrue(codes().contains(""))
    }

    func testIncludesPolish() {
        XCTAssertTrue(codes().contains("pl"), "Polish (pl) missing from WhisperKit language picker — issue #256")
    }

    func testIncludesCzech() {
        XCTAssertTrue(codes().contains("cs"), "Czech (cs) missing from WhisperKit language picker")
    }

    func testIncludesRussian() {
        XCTAssertTrue(codes().contains("ru"), "Russian (ru) missing from WhisperKit language picker")
    }

    func testIncludesUkrainian() {
        XCTAssertTrue(codes().contains("uk"), "Ukrainian (uk) missing from WhisperKit language picker")
    }

    func testNoDuplicateCodes() {
        let allCodes = codes()
        XCTAssertEqual(
            allCodes.count,
            Set(allCodes).count,
            "WhisperKit language picker contains duplicate language codes",
        )
    }
}
