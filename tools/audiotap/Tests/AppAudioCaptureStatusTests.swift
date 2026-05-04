@testable import AudioTapLib
import XCTest

@available(macOS 14.2, *)
final class AppAudioCaptureStatusTests: XCTestCase {
    func test_describeTapError_permissionDenied_mentionsPermission() {
        let msg = AppAudioCapture.describeTapError(-12_988)
        XCTAssertTrue(
            msg.lowercased().contains("permission") || msg.contains("Privacy"),
            "Expected hint about permissions/Privacy, got: \(msg)",
        )
    }

    func test_describeTapError_invalidProperty_mentionsTargetExited() {
        let msg = AppAudioCapture.describeTapError(-10_851)
        XCTAssertTrue(msg.contains("exited") || msg.contains("Invalid"))
    }

    func test_describeTapError_paramErr_mentionsInvalidParameters() {
        let msg = AppAudioCapture.describeTapError(-50)
        XCTAssertTrue(msg.contains("invalid") || msg.contains("parameter"))
    }

    func test_describeTapError_unknown_includesNumericCode() {
        let msg = AppAudioCapture.describeTapError(-99_999)
        XCTAssertTrue(msg.contains("-99999"))
    }
}
