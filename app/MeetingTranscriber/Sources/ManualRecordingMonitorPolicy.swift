import Foundation

/// Decision returned by `ManualRecordingMonitorPolicy.step` on each poll
/// of `WatchLoop.monitorManualRecording`. Both stop cases carry their
/// reason so the caller can emit the matching log line.
enum ManualRecordingMonitorDecision: Equatable {
    case continuePolling
    case stopPidExited
    case stopMaxDurationExceeded
}

/// Pure decision logic for `WatchLoop.monitorManualRecording`. Splits
/// the poll-loop's two stop conditions (monitored process died, max
/// recording duration exceeded) out of the async loop so they can be
/// asserted directly without driving a real subprocess.
///
/// Mirrors the `WatchLoopEndPolicy` shape established for
/// `waitForMeetingEnd` — same split between the async runner (timing
/// + side effects) and a pure-function decision.
enum ManualRecordingMonitorPolicy {
    /// Decide whether the monitor should keep polling or stop because
    /// the monitored process exited or the recording reached its
    /// duration cap.
    ///
    /// - Parameters:
    ///   - pidAlive: Whether the process the recorder is monitoring is
    ///     still alive. Production checks this with `kill(pid, 0) == 0`.
    ///   - elapsed: Time elapsed since the monitor started.
    ///   - maxDuration: Absolute cap on recording duration.
    /// - Returns: `.stopPidExited` first if the process died, otherwise
    ///   `.stopMaxDurationExceeded` if elapsed >= maxDuration, otherwise
    ///   `.continuePolling`. Pid-exit wins on ties so a process that
    ///   dies exactly at the max-duration boundary surfaces as a clean
    ///   exit rather than a timeout.
    static func step(
        pidAlive: Bool,
        elapsed: TimeInterval,
        maxDuration: TimeInterval,
    ) -> ManualRecordingMonitorDecision {
        if !pidAlive {
            return .stopPidExited
        }
        if elapsed > maxDuration {
            return .stopMaxDurationExceeded
        }
        return .continuePolling
    }
}
