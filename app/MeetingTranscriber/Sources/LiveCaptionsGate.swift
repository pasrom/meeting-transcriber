/// Pure decision logic for whether live captions run, and which per-channel
/// streaming backend they use. Shared single source of truth between
/// `AppState.shouldShowLiveCaptions` (overlay-window visibility),
/// `LiveTranscriptionCoordinator` (whether to build + arm the controller), and
/// `LiveTranscriptionController` (which pipeline each channel gets) so all three
/// agree. Pure + value-typed → unit-testable as a truth table without
/// constructing the actors.
///
/// **Master toggle (`liveEnabled`) gates everything** — off means no captions,
/// regardless of the other inputs.
///
/// **The backend follows the active engine's EXPLICITLY configured language**
/// (not auto-detect): `de` → German Nemotron streaming, `en` → English Parakeet
/// EOU streaming. Both streaming sessions drive their FluidAudio models directly
/// and never touch the active `TranscribingEngine`, so they are available even
/// for engines without the re-transcribe hook. Auto-detect (nil language) or any
/// other language deliberately does NOT route to a streaming model — the spoken
/// language isn't statically known, and a wrong-language model is worse than the
/// engine-driven `.reTranscribe` fallback.
enum LiveCaptionsGate {
    /// Which per-channel pipeline strategy to build, or none.
    enum Strategy: Equatable {
        /// Low-latency streaming session via Nemotron multilingual (any explicitly
        /// configured non-English language). FluidAudio auto-selects the Latin or
        /// full multilingual model variant from the language. Engine-independent.
        case nemotronStreaming
        /// Low-latency English streaming session (Parakeet EOU). Engine-independent.
        case englishStreaming
        /// VAD + re-transcribe via the active engine.
        case reTranscribe
        /// Captions are off — build nothing.
        case none // swiftlint:disable:this discouraged_none_name
    }

    /// Resolve the active strategy from the gate inputs.
    ///
    /// English routes to the English-optimized EOU path; any other explicitly
    /// configured language routes to Nemotron multilingual (the manager + its
    /// `downloadVariant` pick the right model + prompt). Auto-detect (nil) does
    /// NOT pick a language-specific streaming model — it falls back to the
    /// engine-driven re-transcribe path.
    ///
    /// - Parameters:
    ///   - liveEnabled: master live-captions toggle.
    ///   - engineLanguage: the active engine's explicitly configured language
    ///     (ISO 639-1, e.g. `de`/`en`), or `nil` for auto-detect.
    ///   - engineSupportsLive: whether the active engine implements the
    ///     in-memory `transcribeSamples` re-transcribe hook.
    static func strategy(
        liveEnabled: Bool,
        engineLanguage: String?,
        engineSupportsLive: Bool,
    ) -> Strategy {
        guard liveEnabled else { return .none }
        guard let engineLanguage else { return engineSupportsLive ? .reTranscribe : .none }
        return engineLanguage == "en" ? .englishStreaming : .nemotronStreaming
    }

    /// Whether live captions are available at all (any non-`none` strategy).
    /// Drives the coordinator's eligibility gate + the overlay-visibility gate
    /// (the latter ANDs in the recording-in-progress condition separately).
    static func captionsAvailable(
        liveEnabled: Bool,
        engineLanguage: String?,
        engineSupportsLive: Bool,
    ) -> Bool {
        strategy(
            liveEnabled: liveEnabled,
            engineLanguage: engineLanguage,
            engineSupportsLive: engineSupportsLive,
        ) != .none
    }
}
