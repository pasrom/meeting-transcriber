@testable import AudioTapLib
import XCTest

final class MicRestartPolicyTests: XCTestCase {
    // MARK: - Skip Cases

    func testSkipsWhenNotRecording() {
        let action = MicRestartPolicy.decideRestart(
            isRecording: false,
            isRestarting: false,
            selectedDeviceUID: nil,
            isSelectedDeviceAvailable: false,
        )
        XCTAssertEqual(action, .skip)
    }

    func testSkipsWhenAlreadyRestarting() {
        let action = MicRestartPolicy.decideRestart(
            isRecording: true,
            isRestarting: true,
            selectedDeviceUID: nil,
            isSelectedDeviceAvailable: false,
        )
        XCTAssertEqual(action, .skip)
    }

    func testSkipsWhenNotRecordingEvenWithSelectedDevice() {
        let action = MicRestartPolicy.decideRestart(
            isRecording: false,
            isRestarting: false,
            selectedDeviceUID: "com.apple.airpods",
            isSelectedDeviceAvailable: true,
        )
        XCTAssertEqual(action, .skip)
    }

    // MARK: - Restart with System Default

    func testRestartsWithDefaultWhenNoDeviceSelected() {
        let action = MicRestartPolicy.decideRestart(
            isRecording: true,
            isRestarting: false,
            selectedDeviceUID: nil,
            isSelectedDeviceAvailable: false,
        )
        XCTAssertEqual(action, .restart(deviceUID: nil))
    }

    // MARK: - Restart with Selected Device

    func testRestartsWithSelectedDeviceWhenAvailable() {
        let action = MicRestartPolicy.decideRestart(
            isRecording: true,
            isRestarting: false,
            selectedDeviceUID: "com.apple.airpods",
            isSelectedDeviceAvailable: true,
        )
        XCTAssertEqual(action, .restart(deviceUID: "com.apple.airpods"))
    }

    // MARK: - Device Fallback

    func testFallsBackToDefaultWhenSelectedDeviceGone() {
        let action = MicRestartPolicy.decideRestart(
            isRecording: true,
            isRestarting: false,
            selectedDeviceUID: "com.apple.airpods",
            isSelectedDeviceAvailable: false,
        )
        XCTAssertEqual(action, .restart(deviceUID: nil))
    }

    // MARK: - Edge Cases

    func testEmptyDeviceUIDTreatedAsSelected() {
        // Empty string is still a non-nil selectedDeviceUID
        let action = MicRestartPolicy.decideRestart(
            isRecording: true,
            isRestarting: false,
            selectedDeviceUID: "",
            isSelectedDeviceAvailable: false,
        )
        // Empty UID not available → falls back to default
        XCTAssertEqual(action, .restart(deviceUID: nil))
    }

    func testBothFlagsBlockRestart() {
        // Not recording AND already restarting
        let action = MicRestartPolicy.decideRestart(
            isRecording: false,
            isRestarting: true,
            selectedDeviceUID: "com.apple.airpods",
            isSelectedDeviceAvailable: true,
        )
        XCTAssertEqual(action, .skip)
    }
}
