import Foundation
import XCTest

@testable import MeetingTranscriber

final class FormattingHelpersTests: XCTestCase {

    // MARK: - formattedTime

    func testSecondsOnly() {
        XCTAssertEqual(formattedTime(45), "45s")
    }

    func testZeroSeconds() {
        XCTAssertEqual(formattedTime(0), "0s")
    }

    func testExactMinute() {
        XCTAssertEqual(formattedTime(60), "1:00")
    }

    func testMinutesAndSeconds() {
        XCTAssertEqual(formattedTime(125), "2:05")
    }

    func testFractionalSeconds() {
        XCTAssertEqual(formattedTime(90.7), "1:30")
    }
}
