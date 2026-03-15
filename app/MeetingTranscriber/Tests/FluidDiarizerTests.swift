@testable import MeetingTranscriber
import XCTest

final class FluidDiarizerTests: XCTestCase {
    func testIsAlwaysAvailable() {
        let diarizer = FluidDiarizer()
        XCTAssertTrue(diarizer.isAvailable)
    }
}
