import Foundation

/// Pure state machine for the "output device changed mid-capture, restart the tap"
/// flow used by AppAudioCapture. The host class drives the actual CoreAudio I/O
/// and async dispatches; this struct decides *when* and *what* to dispatch.
///
/// Lifecycle (one cycle per device change):
///   .idle → deviceChanged          → .restarting    + .stopAndRetry(initial)
///   .restarting → succeeded(rate>0)  → .idle         + .complete
///   .restarting → succeeded(rate≤0)  → .retrying(1) + .stopAndRetry(backoff)
///   .restarting → failed             → .retrying(1) + .restart(backoff)
///   .retrying(n) → succeeded(rate>0)           → .idle + .complete
///   .retrying(n) → succeeded(rate≤0) | failed  → .retrying(n+1) while the
///     shared retry policy still grants an attempt, otherwise .idle + .giveUp
///   deviceChanged while not idle is ignored.
///
/// Not Equatable: it carries the injected retry policy now, and nothing ever
/// compared two coordinators. Tests compare `state`.
struct OutputDeviceChangeCoordinator {
    enum State: Equatable {
        case idle
        case restarting
        /// How many retries have already been spent. The budget and the backoff
        /// come from `CaptureRestartRetryPolicy`, the same one the microphone
        /// channel uses.
        case retrying(attemptsSoFar: Int)
    }

    enum Event: Equatable {
        case deviceChanged
        case startSucceeded(rate: Int)
        case startFailed
    }

    enum Action: Equatable {
        case ignore
        /// Run stopCapture, then dispatch startCapture after the given delay.
        case stopAndRetry(delay: TimeInterval)
        /// Dispatch startCapture after the given delay (no extra stopCapture —
        /// the previous start attempt already failed and left things stopped).
        case restart(delay: TimeInterval)
        /// Successfully restarted; reset any "is restarting" guards.
        case complete
        /// Retry failed; reset guards and log an error.
        case giveUp
    }

    private(set) var state: State = .idle
    let initialRestartDelay: TimeInterval
    /// How long to wait before the next retry, and when to stop retrying.
    /// Injected so tests can use a fast schedule; production shares the
    /// microphone channel's, because both channels are reacting to the same
    /// device going away.
    let decideRetry: @Sendable (Int) -> CaptureRestartRetryAction

    init(
        initialRestartDelay: TimeInterval = 0.5,
        decideRetry: @escaping @Sendable (Int) -> CaptureRestartRetryAction
            = CaptureRestartRetryPolicy.decide,
    ) {
        self.initialRestartDelay = initialRestartDelay
        self.decideRetry = decideRetry
    }

    /// Turn the shared policy's verdict into this machine's next state.
    private mutating func afterFailedAttempt(
        attemptsSoFar: Int, stopFirst: Bool,
    ) -> Action {
        switch decideRetry(attemptsSoFar) {
        case let .retry(delay):
            state = .retrying(attemptsSoFar: attemptsSoFar + 1)
            return stopFirst ? .stopAndRetry(delay: delay) : .restart(delay: delay)

        case .giveUp:
            state = .idle
            return .giveUp
        }
    }

    mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .deviceChanged):
            state = .restarting
            return .stopAndRetry(delay: initialRestartDelay)

        case let (.restarting, .startSucceeded(rate)) where rate > 0:
            state = .idle
            return .complete

        // A start that reports rate 0 is a failure wearing a success's clothes:
        // the tap came up against a device that is not delivering.
        case (.restarting, .startSucceeded):
            return afterFailedAttempt(attemptsSoFar: 0, stopFirst: true)

        case (.restarting, .startFailed):
            return afterFailedAttempt(attemptsSoFar: 0, stopFirst: false)

        case let (.retrying(_), .startSucceeded(rate)) where rate > 0:
            state = .idle
            return .complete

        case let (.retrying(attempts), .startSucceeded):
            return afterFailedAttempt(attemptsSoFar: attempts, stopFirst: true)

        case let (.retrying(attempts), .startFailed):
            return afterFailedAttempt(attemptsSoFar: attempts, stopFirst: false)

        case (.restarting, .deviceChanged), (.retrying, .deviceChanged):
            return .ignore

        case (.idle, .startSucceeded), (.idle, .startFailed):
            return .ignore
        }
    }
}
