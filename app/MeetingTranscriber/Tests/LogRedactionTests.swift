import XCTest
@testable import MeetingTranscriber

final class LogRedactionTests: XCTestCase {
    func test_pseudonymized_isStable() {
        XCTAssertEqual("Roman".pseudonymized, "Roman".pseudonymized)
    }

    func test_pseudonymized_differsAcrossNames() {
        XCTAssertNotEqual("Roman".pseudonymized, "Anna".pseudonymized)
    }

    func test_pseudonymized_format() {
        let p = "Roman".pseudonymized
        XCTAssertTrue(p.hasPrefix("speaker_"))
        XCTAssertEqual(p.count, "speaker_".count + 4)
        XCTAssertTrue(p.dropFirst("speaker_".count).allSatisfy { "0123456789abcdef".contains($0) })
    }

    func test_pseudonymized_emptyString_returnsAnonymous() {
        XCTAssertEqual("".pseudonymized, "speaker_anon")
    }

    func test_redactedName_long() {
        XCTAssertEqual("Roman".redactedName, "R***n")
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
