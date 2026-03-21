@testable import MeetingTranscriber
import XCTest

final class AudioConstantsTests: XCTestCase {
    func testTargetSampleRateIs16000() {
        XCTAssertEqual(AudioConstants.targetSampleRate, 16000)
    }
}
