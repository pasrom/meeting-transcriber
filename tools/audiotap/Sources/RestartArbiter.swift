import Foundation

/// Phase machine that bounds a *single* capture-restart attempt (issue #588).
///
/// Why this exists: a restart attempt can enter an unbounded loop inside AVFAudio
/// and never return. `-[AVAudioEngine inputNode]` on a fresh engine loops in
/// `AVAudioIOUnit_OSX::_GetHWFormat` when the per-process default-device
/// aggregate still holds dangling sub-device references to a Bluetooth device
/// that just vanished. The call cannot be cancelled, and in the field it returned
/// only when the device came back three hours later.
///
/// `MicRestartRetryPolicy` bounds how *many* attempts are made and is unaffected:
/// a restart that fails is the transient case it was built for. This type bounds
/// how *long* one attempt may take, and it makes the outcome safe if a wedged
/// attempt eventually returns:
///
/// - every attempt carries a generation, and a result whose generation is no
///   longer current is rejected rather than adopted,
/// - once an attempt has timed out, output-file creation is forbidden forever,
///   because the restart path recreates the WAV for writing when it finds no
///   open file, which would truncate the finished recording to zero,
/// - `stop()` learns that it must not touch the engine while an attempt is in
///   flight, since the wedged attempt holds the engine's mutex.
///
/// Pure value type so the whole transition table is unit-testable without an
/// engine, following `OutputDeviceChangeCoordinator` and `MicRestartRetryPolicy`.
struct RestartArbiter: Equatable {
    /// How long a single restart attempt may take before it counts as wedged.
    ///
    /// A healthy restart completes in roughly 300 ms (measured). The timeout only
    /// has to separate "never returns" from "slow", so it sits far above the
    /// healthy case: the cost of firing too early is a sacrificed microphone
    /// track on a Bluetooth renegotiation that would have succeeded.
    static let attemptTimeout: TimeInterval = 5.0

    enum Phase: Equatable {
        /// Nothing captured yet, or never started.
        case idle
        /// Capturing normally; no restart outstanding.
        case capturing
        /// A restart attempt was launched and has not reported back. It may be
        /// wedged, so nothing may touch the engine and no second attempt starts.
        case attemptInFlight(generation: Int)
        /// An attempt came back with an error and the next one is waiting out its
        /// backoff. A device change here is deliberately ignored: a flapping
        /// device would otherwise skip the pacing by supplying a fresh event.
        case backingOff
        /// An attempt succeeded and is waiting to be adopted. The work exists but
        /// is published to nothing yet, so a stop arriving now still wins.
        case committing(generation: Int)
        /// The track was abandoned, either because an attempt exceeded
        /// `attemptTimeout` or because the retry budget ran out. Terminal: the
        /// wedged thread and its engine are unrecoverable, and a further attempt
        /// in the same process can wedge again because HAL client state is
        /// process-global.
        case gaveUp
        /// `stop()` was honoured. Terminal.
        case stopped
    }

    enum Event: Equatable {
        /// Capture started (or restarted) successfully.
        case startSucceeded
        /// The default input device changed underneath us.
        case deviceChanged
        /// A launched attempt reported back. Carries its own generation so a
        /// late report from a superseded attempt can be told apart.
        case attemptReturned(generation: Int, succeeded: Bool)
        /// A successful attempt reached the queue that owns publication and is
        /// asking to be adopted.
        case commitReady(generation: Int)
        /// The backoff elapsed. Carries no generation because every control event
        /// except `attemptReturned` arrives on the main queue, so at most one
        /// retry timer exists per backoff.
        case retryDue
        /// The retry budget ran out on attempts that all came back with errors.
        /// Deliberately distinct from `attemptTimedOut`, which is generation
        /// scoped and only meaningful for an attempt that never returned.
        case retryBudgetExhausted
        /// The watchdog for `generation` fired.
        case attemptTimedOut(generation: Int)
        /// `stop()` was called.
        case stopRequested
    }

    enum Action: Equatable {
        case ignore
        /// Launch a restart attempt tagged with this generation.
        case launchAttempt(generation: Int)
        /// The attempt's result is good; hand it to the queue that publishes.
        case commit
        /// Publish the attempt's result now.
        case adopt
        /// Discard the attempt's result and let it tear down whatever it built.
        /// It must not touch shared state.
        case rejectStale
        /// The track is abandoned: either an attempt never returned, or the retry
        /// budget ran out on attempts that did. Seal the session and notify; a
        /// channel that owns an output file also finalizes it. Never retry.
        case giveUp
        /// The attempt returned an error. The existing backoff budget applies.
        case retry
        /// Normal `stop()`: touching the engine is safe.
        case teardown
        /// `stop()` while wedged or after giving up: seal the state and leave the
        /// engine alone, or the caller wedges too.
        case sealAndSkipEngine
    }

    private(set) var phase: Phase = .idle
    private var generation = 0

    /// False once the session is sealed. The restart path creates the output file
    /// whenever it finds none open, so a late-returning wedged attempt would
    /// otherwise overwrite a recording that was already finalized.
    var mayCreateOutputFile: Bool {
        switch phase {
        case .idle, .capturing, .attemptInFlight, .backingOff, .committing: true
        case .gaveUp, .stopped: false
        }
    }

    /// True only while capture is actually running: the render-thread tap block
    /// uses this to short-circuit once a restart, a give-up or a stop has begun.
    var isCapturing: Bool {
        phase == .capturing
    }

    mutating func handle(_ event: Event) -> Action {
        switch (phase, event) {
        case (.idle, .startSucceeded), (.capturing, .startSucceeded):
            phase = .capturing
            return .ignore

        case (.capturing, .deviceChanged), (.capturing, .retryDue), (.backingOff, .retryDue):
            generation += 1
            phase = .attemptInFlight(generation: generation)
            return .launchAttempt(generation: generation)

        case let (.attemptInFlight(current), .attemptReturned(reported, succeeded)) where reported == current:
            phase = succeeded ? .committing(generation: current) : .backingOff
            return succeeded ? .commit : .retry

        case let (.committing(current), .commitReady(reported)) where reported == current:
            phase = .capturing
            return .adopt

        // Only an attempt that is still outstanding can time out. Once it has
        // returned, the generation still matches for a moment while the commit
        // hops queues; letting the match win there would kill a healthy restart.
        case let (.attemptInFlight(current), .attemptTimedOut(reported)) where reported == current:
            phase = .gaveUp
            return .giveUp

        case (.backingOff, .retryBudgetExhausted):
            phase = .gaveUp
            return .giveUp

        case (.attemptInFlight, .stopRequested), (.gaveUp, .stopRequested):
            phase = .stopped
            return .sealAndSkipEngine

        // Nothing holds the engine here: either no attempt is outstanding, or the
        // one that was has already returned. Sealing instead would leave a live
        // engine running until deinit.
        case (.idle, .stopRequested), (.capturing, .stopRequested),
             (.backingOff, .stopRequested), (.committing, .stopRequested):
            phase = .stopped
            return .teardown

        // A result from an attempt that is no longer the current one. Reachable
        // hours later: the wedged call does return if the device comes back.
        case (_, .attemptReturned), (_, .commitReady):
            return .rejectStale

        // A watchdog whose attempt already reported back, or any control event in
        // a sealed session.
        case (_, .attemptTimedOut), (_, .deviceChanged), (_, .startSucceeded),
             (_, .stopRequested), (_, .retryDue), (_, .retryBudgetExhausted):
            return .ignore
        }
    }
}
