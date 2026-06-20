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
        /// Low-latency streaming session via Nemotron multilingual (one of the
        /// Latin-script languages in `nemotronLanguages`). Engine-independent.
        case nemotronStreaming
        /// Low-latency English streaming session (Parakeet EOU). Engine-independent.
        case englishStreaming
        /// VAD + re-transcribe via the active engine.
        case reTranscribe
        /// Captions are off — build nothing.
        case none // swiftlint:disable:this discouraged_none_name
    }

    /// Languages the Nemotron multilingual "latin" model transcribes well (its
    /// vocab is pruned to Latin-script). English is excluded on purpose — it
    /// routes to the English-optimized EOU streaming path instead. ISO 639-1,
    /// matching the engine language pickers + the model's prompt dictionary.
    static let nemotronLanguages: Set<String> = ["de", "es", "fr", "it", "pt"]

    /// Resolve the active strategy from the gate inputs.
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
        if engineLanguage == "en" { return .englishStreaming }
        if let engineLanguage, nemotronLanguages.contains(engineLanguage) { return .nemotronStreaming }
        return engineSupportsLive ? .reTranscribe : .none
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
