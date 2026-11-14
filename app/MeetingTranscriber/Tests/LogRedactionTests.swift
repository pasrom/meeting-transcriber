@testable import MeetingTranscriber
import XCTest

final class LogRedactionTests: XCTestCase {
    func test_pseudonymized_isStable() {
        XCTAssertEqual("Speaker A".pseudonymized, "Speaker A".pseudonymized)
    }

    func test_pseudonymized_differsAcrossNames() {
        XCTAssertNotEqual("Speaker A".pseudonymized, "Anna".pseudonymized)
    }

    func test_pseudonymized_format() {
        let p = "Speaker A".pseudonymized
        XCTAssertTrue(p.hasPrefix("speaker_"))
        XCTAssertEqual(p.count, "speaker_".count + 4)
        XCTAssertTrue(p.dropFirst("speaker_".count).allSatisfy { "0123456789abcdef".contains($0) })
    }

    func test_pseudonymized_emptyString_returnsAnonymous() {
        XCTAssertEqual("".pseudonymized, "speaker_anon")
    }

    func test_redactedName_long() {
        XCTAssertEqual("Speaker A".redactedName, "S*******A")
    }

    func test_redactedName_short3() {
        XCTAssertEqual("Tom".redactedName, "T**")
    }

    func test_redactedName_two() {
        XCTAssertEqual("Li".redactedName, "L*")
    }

    func test_redactedName_one() {
        XCTAssertEqual("X".redactedName, "*")
    }

    func test_redactedName_empty() {
        XCTAssertEqual("".redactedName, "")
    }

    func test_redactedName_unicode() {
        XCTAssertEqual("Ümlaut".redactedName, "Ü****t")
    }
}
