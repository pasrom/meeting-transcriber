import Foundation

/// Pure state machine for the "output device changed mid-capture, restart the tap"
/// flow used by AppAudioCapture. The host class drives the actual CoreAudio I/O
/// and async dispatches; this struct decides *when* and *what* to dispatch.
///
/// Lifecycle (one cycle per device change):
///   .idle → deviceChanged          → .restarting    + .stopAndRetry(initial)
///   .restarting → succeeded(rate>0)  → .idle         + .complete
///   .restarting → succeeded(rate≤0)  → .retryPending + .stopAndRetry(retry)
///   .restarting → failed             → .retryPending + .restart(retry)
///   .retryPending → succeeded(rate>0)            → .idle + .complete
///   .retryPending → succeeded(rate≤0) | failed   → .idle + .giveUp
///   deviceChanged while not idle is ignored.
struct OutputDeviceChangeCoordinator: Equatable {
    enum State: Equatable {
        case idle
        case restarting
        case retryPending
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
    let retryDelay: TimeInterval

    init(initialRestartDelay: TimeInterval = 0.5, retryDelay: TimeInterval = 1.0) {
        self.initialRestartDelay = initialRestartDelay
        self.retryDelay = retryDelay
    }

    mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .deviceChanged):
            state = .restarting
            return .stopAndRetry(delay: initialRestartDelay)

        case let (.restarting, .startSucceeded(rate)) where rate > 0:
            state = .idle
            return .complete

        case (.restarting, .startSucceeded):
            state = .retryPending
            return .stopAndRetry(delay: retryDelay)

        case (.restarting, .startFailed):
            state = .retryPending
            return .restart(delay: retryDelay)

        case let (.retryPending, .startSucceeded(rate)) where rate > 0:
            state = .idle
            return .complete

        case (.retryPending, .startSucceeded), (.retryPending, .startFailed):
            state = .idle
            return .giveUp

        case (.restarting, .deviceChanged), (.retryPending, .deviceChanged):
            return .ignore

        case (.idle, .startSucceeded), (.idle, .startFailed):
            return .ignore
        }
    }
}
