@testable import MeetingTranscriber
import XCTest

final class MicRecorderTests: XCTestCase {
    // MARK: - Initial State

    func testInitialStateNotRecording() {
        let recorder = MicRecorder()
        XCTAssertFalse(recorder.isRecording)
    }

    func testStopWhenNotRecordingIsNoOp() {
        let recorder = MicRecorder()
        recorder.stop()
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - Error Descriptions

    func testErrorFormatCreationFailed() {
        let error = MicRecorderError.formatCreationFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(
            error.errorDescription?.contains("Failed to create audio format"),
            true,
            "Expected 'Failed to create audio format', got: \(error.errorDescription ?? "nil")",
        )
    }

    func testErrorDeviceNotFound() {
        let error = MicRecorderError.deviceNotFound("TestUID")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(
            error.errorDescription?.contains("TestUID"),
            true,
            "Expected description to contain 'TestUID', got: \(error.errorDescription ?? "nil")",
        )
    }

    func testErrorDeviceSetFailed() {
        let error = MicRecorderError.deviceSetFailed("TestUID", -50)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(
            error.errorDescription?.contains("TestUID"),
            true,
            "Expected description to contain 'TestUID', got: \(error.errorDescription ?? "nil")",
        )
        XCTAssertEqual(
            error.errorDescription?.contains("-50"),
            true,
            "Expected description to contain '-50', got: \(error.errorDescription ?? "nil")",
        )
    }
}
