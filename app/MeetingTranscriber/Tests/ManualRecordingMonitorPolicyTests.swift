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
                target: .alive, elapsed: 10, maxDuration: 100,
            ),
            .continuePolling,
        )
    }

    // MARK: - Pid exit

    func testStopsWhenProcessExited() {
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                target: .exited, elapsed: 10, maxDuration: 100,
            ),
            .stopPidExited,
        )
    }

    func testPidExitWinsOverMaxDurationOnTie() {
        // Both conditions met simultaneously — pid-exit is the cleaner
        // signal and should win.
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                target: .exited, elapsed: 200, maxDuration: 100,
            ),
            .stopPidExited,
        )
    }

    // MARK: - Max duration

    func testStopsWhenElapsedStrictlyGreaterThanMaxDuration() {
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                target: .alive, elapsed: 100.5, maxDuration: 100,
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
                target: .alive, elapsed: 100, maxDuration: 100,
            ),
            .continuePolling,
        )
    }

    // MARK: - No target process (microphone-only recording)

    func testKeepsPollingWithNoTargetProcess() {
        // A mic-only recording has no process whose exit could end it, so the
        // absence must read as "nothing to stop for", not as an exit. Both
        // bools were wrong here, which is why this is a third case: `.alive`
        // would claim a liveness check that never ran.
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                target: .untargeted, elapsed: 10, maxDuration: 100,
            ),
            .continuePolling,
        )
    }

    func testDurationCapStillAppliesWithNoTargetProcess() {
        // The remaining stop condition. Without it a mic-only recording that
        // the user forgets about would run until the app quits.
        XCTAssertEqual(
            ManualRecordingMonitorPolicy.step(
                target: .untargeted, elapsed: 100.5, maxDuration: 100,
            ),
            .stopMaxDurationExceeded,
        )
    }
}
