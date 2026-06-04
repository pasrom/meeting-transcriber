import Foundation

/// Action to take after a mic-engine restart attempt failed.
public enum MicRestartRetryAction: Equatable {
    /// Retry the restart after the given backoff delay (seconds).
    case retry(afterSeconds: Double)
    /// Stop retrying — the failure budget is exhausted.
    case giveUp
}

/// Pure decision logic for retrying a failed mic-engine restart (issue #379).
/// A device change can briefly expose an invalid format and make the restart
/// throw; retrying with backoff lets a transient settle instead of dropping
/// the recording. Separated from MicCaptureHandler so the backoff schedule and
/// give-up boundary are unit-testable without hardware.
public enum MicRestartRetryPolicy {
    /// Maximum number of retries before giving up.
    public static let maxAttempts = 5

    /// First-retry backoff; doubles each subsequent attempt up to `maxBackoff`.
    static let baseBackoff = 0.3
    static let maxBackoff = 2.0

    /// Decide whether to retry after a failed restart.
    ///
    /// - Parameter attemptsSoFar: retries already performed (0 on the first
    ///   failure, 1 after one retry, …).
    /// - Returns: `.retry` with an exponentially-backed-off delay while within
    ///   budget, otherwise `.giveUp`.
    public static func decide(attemptsSoFar: Int) -> MicRestartRetryAction {
        guard attemptsSoFar < maxAttempts else { return .giveUp }
        let delay = min(baseBackoff * pow(2.0, Double(attemptsSoFar)), maxBackoff)
        return .retry(afterSeconds: delay)
    }
}
