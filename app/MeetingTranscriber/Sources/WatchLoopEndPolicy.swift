import Foundation

/// Decision returned by `WatchLoopEndPolicy.step` on each poll of
/// `WatchLoop.waitForMeetingEnd`.
enum WatchLoopEndDecision: Equatable {
    /// Continue polling. The returned `graceStart` is the value the caller
    /// should hold until the next poll: `nil` when the meeting is currently
    /// active (grace cleared), the original value when grace is still
    /// running, or `now` when a fresh grace window just started.
    case continuePolling(graceStart: Date?)
    /// Stop because the recording has exceeded its maximum duration. The
    /// caller is responsible for logging this case if it wants to.
    case stopMaxDurationExceeded
    /// Stop because the meeting has been inactive for the full grace
    /// period — the meeting is definitively over.
    case stopGraceExpired
}

/// Static configuration for `WatchLoopEndPolicy.step` — duration limits
/// owned by the WatchLoop instance and re-used across every poll.
struct WatchLoopEndConfig: Equatable {
    let maxDuration: TimeInterval
    let endGracePeriod: TimeInterval
}

/// Pure decision logic for `WatchLoop.waitForMeetingEnd`. Separated so
/// the grace-reset / max-duration / continue-on-active branches can be
/// asserted directly without driving the async timer loop.
enum WatchLoopEndPolicy {
    /// Decide what the meeting-end poller should do given the current
    /// state of the world.
    ///
    /// - Parameters:
    ///   - config: Duration limits (max recording duration + end-of-meeting
    ///     grace period).
    ///   - now: The current wall-clock time. Pass `Date()` from production.
    ///   - startTime: When the poller first started waiting for end.
    ///   - graceStart: When the current inactive run started, or `nil`
    ///     if the meeting was active on the last poll (or has never gone
    ///     inactive).
    ///   - meetingActive: Whether the meeting is active right now.
    static func step(
        config: WatchLoopEndConfig,
        now: Date,
        startTime: Date,
        graceStart: Date?,
        meetingActive: Bool,
    ) -> WatchLoopEndDecision {
        if now.timeIntervalSince(startTime) > config.maxDuration {
            return .stopMaxDurationExceeded
        }
        if meetingActive {
            return .continuePolling(graceStart: nil)
        }
        guard let start = graceStart else {
            return .continuePolling(graceStart: now)
        }
        if now.timeIntervalSince(start) >= config.endGracePeriod {
            return .stopGraceExpired
        }
        return .continuePolling(graceStart: start)
    }
}
