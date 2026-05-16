@testable import MeetingTranscriber
import XCTest

/// Same class of bug as issue #256 but for Parakeet TDT v3. FluidAudio's
/// `AsrManager.transcribe(_:decoderState:language:)` takes an optional
/// `FluidAudio.Language` hint (18 codes incl. pl/cs/sk/sl/hr/bs/ru/uk/be/bg/sr)
/// for script-aware token filtering — the decoder otherwise drifts to Cyrillic
/// while transcribing Polish (FluidAudio's own `TokenLanguageFilter.swift`
/// header cites their issue #512). Our `ParakeetEngine` wrapper has to expose
/// that hint via a picker; without it, a Polish/Czech user has the same "no
/// way to set my language" problem as WhisperKit's #256.
final class ParakeetLanguagePickerTests: XCTestCase {
    private func codes() -> [String] {
        PickerLanguages.parakeet.map(\.code)
    }

    func testIncludesAutoDetect() {
        XCTAssertTrue(codes().contains(""), "Auto-detect sentinel missing from Parakeet picker")
    }

    func testIncludesPolish() {
        XCTAssertTrue(codes().contains("pl"), "Polish (pl) missing from Parakeet picker — same class as issue #256")
    }

    func testIncludesCzech() {
        XCTAssertTrue(codes().contains("cs"), "Czech (cs) missing from Parakeet picker")
    }

    func testIncludesRussian() {
        XCTAssertTrue(codes().contains("ru"), "Russian (ru) missing from Parakeet picker")
    }

    func testIncludesUkrainian() {
        XCTAssertTrue(codes().contains("uk"), "Ukrainian (uk) missing from Parakeet picker")
    }

    func testNoDuplicateCodes() {
        let allCodes = codes()
        XCTAssertEqual(allCodes.count, Set(allCodes).count, "Duplicate language codes in Parakeet picker")
    }
}
