import Foundation

/// Action to take after a capture restart attempt failed.
public enum CaptureRestartRetryAction: Equatable {
    /// Retry the restart after the given backoff delay (seconds).
    case retry(afterSeconds: Double)
    /// Stop retrying — the failure budget is exhausted.
    case giveUp
}

/// Pure decision logic for retrying a failed capture restart (issue #379).
/// A device change can briefly expose an invalid format and make the restart
/// throw; retrying with backoff lets a transient settle instead of dropping
/// the recording. Kept as a value type so the backoff schedule and the give-up
/// boundary are unit-testable without hardware.
///
/// Shared by both channels on purpose. They face the same event, a device that
/// went away and is coming back, and a device that needs three seconds to
/// re-enumerate should not cost one channel its track while the other rides it
/// out. Two schedules would drift apart at the first tuning change.
public enum CaptureRestartRetryPolicy {
    /// Maximum number of retries before giving up.
    public static let maxAttempts = 5

    /// First-retry backoff; doubles each subsequent attempt up to `maxBackoff`.
    public static let baseBackoff = 0.3
    static let maxBackoff = 2.0

    /// Decide whether to retry after a failed restart.
    ///
    /// - Parameter attemptsSoFar: retries already performed (0 on the first
    ///   failure, 1 after one retry, …).
    /// - Returns: `.retry` with an exponentially-backed-off delay while within
    ///   budget, otherwise `.giveUp`.
    public static func decide(attemptsSoFar: Int) -> CaptureRestartRetryAction {
        guard attemptsSoFar < maxAttempts else { return .giveUp }
        let delay = min(baseBackoff * pow(2.0, Double(attemptsSoFar)), maxBackoff)
        return .retry(afterSeconds: delay)
    }
}
