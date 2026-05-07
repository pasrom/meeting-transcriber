@testable import AudioTapLib
import Foundation
import XCTest

final class MicCaptureErrorTests: XCTestCase {
    func testNoInputDeviceDescription() {
        let error = MicCaptureError.noInputDevice
        XCTAssertEqual(error.errorDescription, "No microphone hardware available")
    }
}
