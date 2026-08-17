import Foundation

/// Decision returned by `ManualRecordingMonitorPolicy.step` on each poll
/// of `WatchLoop.monitorManualRecording`. Both stop cases carry their
/// reason so the caller can emit the matching log line.
enum ManualRecordingMonitorDecision: Equatable {
    case continuePolling
    case stopPidExited
    case stopMaxDurationExceeded
}

/// What the monitor found when it looked for the process a manual recording is
/// tied to.
///
/// A three-state enum rather than a `Bool` because a microphone-only recording
/// targets no process at all, and the two ways to say that with a bool are both
/// wrong: `true` claims a liveness check that never ran, `false` ends the
/// recording immediately.
enum ManualRecordingTarget: Equatable {
    /// The monitored process is still running.
    case alive
    /// The monitored process has exited, which ends the recording.
    case exited
    /// The recording targets no process, so nothing can exit and only the
    /// duration cap is left to stop it.
    case untargeted
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
    ///   - target: What the monitor found when it looked for the process the
    ///     recording is tied to. Production reads `.alive`/`.exited` from
    ///     `kill(pid, 0) == 0`; `.untargeted` is the microphone-only case.
    ///   - elapsed: Time elapsed since the monitor started.
    ///   - maxDuration: Absolute cap on recording duration.
    /// - Returns: `.stopPidExited` first if the process died, otherwise
    ///   `.stopMaxDurationExceeded` if elapsed >= maxDuration, otherwise
    ///   `.continuePolling`. Pid-exit wins on ties so a process that
    ///   dies exactly at the max-duration boundary surfaces as a clean
    ///   exit rather than a timeout.
    static func step(
        target: ManualRecordingTarget,
        elapsed: TimeInterval,
        maxDuration: TimeInterval,
    ) -> ManualRecordingMonitorDecision {
        if target == .exited {
            return .stopPidExited
        }
        if elapsed > maxDuration {
            return .stopMaxDurationExceeded
        }
        return .continuePolling
    }
}
