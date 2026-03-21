@testable import MeetingTranscriber
import XCTest

final class PermissionsTests: XCTestCase {
    func testCheckScreenRecordingReturnsBool() {
        // Result varies by environment; just verify it returns without crashing
        let result = Permissions.checkScreenRecording()
        XCTAssertNotNil(result)
    }

    func testEnsureMicrophoneAccessReturnsBool() async {
        // Result varies by environment; just verify it returns without crashing
        let result = await Permissions.ensureMicrophoneAccess()
        XCTAssertNotNil(result)
    }
}
