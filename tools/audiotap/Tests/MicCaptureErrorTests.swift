import Foundation
import XCTest

@testable import AudioTapLib

final class MicCaptureErrorTests: XCTestCase {
    func testNoInputDeviceDescription() {
        let error = MicCaptureError.noInputDevice
        XCTAssertEqual(error.errorDescription, "No microphone hardware available")
    }
}
