@testable import MeetingTranscriber
import XCTest

/// Branch-tests for the pure decision function that drives
/// `WatchLoop.monitorManualRecording`. The live path is awkward to
/// exercise (real `kill(pid, 0)` syscall + async timer loop); these
/// tests cover the branch logic without a subprocess.
final class ManualRecordingMonitorPolicyTests: XCTestCase {
    // MARK: - Continue polling

    func testContinuesWhenProcessAliveAndUnderMaxDuration() {
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                pidAlive: true, elapsed: 10, maxDuration: 100,
            ),
            .continuePolling,
        )
    }

    // MARK: - Pid exit

    func testStopsWhenProcessExited() {
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                pidAlive: false, elapsed: 10, maxDuration: 100,
            ),
            .stopPidExited,
        )
    }

    func testPidExitWinsOverMaxDurationOnTie() {
        // Both conditions met simultaneously — pid-exit is the cleaner
        // signal and should win.
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                pidAlive: false, elapsed: 200, maxDuration: 100,
            ),
            .stopPidExited,
        )
    }

    // MARK: - Max duration

    func testStopsWhenElapsedStrictlyGreaterThanMaxDuration() {
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                pidAlive: true, elapsed: 100.5, maxDuration: 100,
            ),
            .stopMaxDurationExceeded,
        )
    }

    func testContinuesWhenElapsedExactlyEqualToMaxDuration() {
        // Strict `>` semantics mean elapsed == maxDuration still polls.
        // Pinned to document the boundary; flip to `>=` deliberately
        // if production behaviour ever changes.
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                pidAlive: true, elapsed: 100, maxDuration: 100,
            ),
            .continuePolling,
        )
    }
}
