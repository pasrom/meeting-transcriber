/// Pure decision logic for whether live captions run, and which per-channel
/// pipeline strategy they use. Shared single source of truth between
/// `AppState.shouldShowLiveCaptions` (overlay-window visibility),
/// `LiveTranscriptionCoordinator` (whether to build + arm the controller), and
/// `LiveTranscriptionController` (which pipeline each channel gets) so all three
/// agree. Pure + value-typed → unit-testable as a truth table without
/// constructing the actors.
///
/// **Master toggle (`liveEnabled`) gates everything** — off means no captions,
/// regardless of the other inputs.
///
/// **`englishStreaming` bypasses the engine-support gate**: the low-latency
/// English streaming session (`EouStreamingCaptionSession`) drives FluidAudio's
/// Parakeet EOU model directly and never touches the active `TranscribingEngine`,
/// so captions become available even for engines without the re-transcribe hook.
/// With `englishStreaming` off, captions still require the engine to support the
/// re-transcribe path (today's behaviour).
enum LiveCaptionsGate {
    /// Which per-channel pipeline strategy to build, or none.
    enum Strategy: Equatable {
        /// Low-latency English streaming session (Parakeet EOU). Engine-independent.
        case englishStreaming
        /// VAD + re-transcribe via the active engine.
        case reTranscribe
        /// Captions are off — build nothing.
        case none // swiftlint:disable:this discouraged_none_name
    }

    /// Resolve the active strategy from the three gate inputs.
    ///
    /// - Parameters:
    ///   - liveEnabled: master live-captions toggle.
    ///   - englishStreaming: the English low-latency opt-in.
    ///   - engineSupportsLive: whether the active engine implements the
    ///     in-memory `transcribeSamples` re-transcribe hook.
    static func strategy(
        liveEnabled: Bool,
        englishStreaming: Bool,
        engineSupportsLive: Bool,
    ) -> Strategy {
        guard liveEnabled else { return .none }
        if englishStreaming { return .englishStreaming }
        return engineSupportsLive ? .reTranscribe : .none
    }

    /// Whether live captions are available at all (any non-`none` strategy).
    /// Drives the coordinator's eligibility gate + the overlay-visibility gate
    /// (the latter ANDs in the recording-in-progress condition separately).
    static func captionsAvailable(
        liveEnabled: Bool,
        englishStreaming: Bool,
        engineSupportsLive: Bool,
    ) -> Bool {
        strategy(
            liveEnabled: liveEnabled,
            englishStreaming: englishStreaming,
            engineSupportsLive: engineSupportsLive,
        ) != .none
    }
}
