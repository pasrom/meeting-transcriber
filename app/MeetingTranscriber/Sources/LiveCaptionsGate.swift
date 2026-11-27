/// Pure decision logic for whether live captions run, and which per-channel
/// streaming backend they use. Shared single source of truth between
/// `LiveTranscriptionCoordinator` (whether to build + arm the controller and,
/// through it, `AppState.shouldShowLiveCaptions` overlay visibility) and
/// `LiveTranscriptionController` (which pipeline each channel gets) so all three
/// agree. Pure + value-typed → unit-testable as a truth table without
/// constructing the actors.
///
/// **Master toggle (`liveEnabled`) still gates the pipeline** — off means no
/// captions, regardless of the other inputs. The overlay toggle only gates the
/// overlay window (`AppState.shouldShowLiveCaptions`); it is not a strategy input.
///
/// **The backend follows the active engine's EXPLICITLY configured language**
/// (not auto-detect): trained non-English languages → Nemotron, English → Parakeet
/// EOU streaming. Both streaming sessions drive their FluidAudio models directly
/// and never touch the active `TranscribingEngine`, so they are available even
/// for engines without the re-transcribe hook. Auto-detect (nil language) and
/// languages outside `LiveCaptionLanguages` use the engine-driven `.reTranscribe`
/// fallback when supported, otherwise captions are off.
///
/// **Cloud transcription keeps captions off the local engine.** With it on,
/// `.reTranscribe` becomes `.none`: that path loads the local model, which
/// `EngineController` frees while cloud is on. The streaming backends stay.
enum LiveCaptionsGate {
    /// Which per-channel pipeline strategy to build, or none.
    enum Strategy: Equatable {
        /// Low-latency streaming session via Nemotron multilingual (an explicitly
        /// configured, trained non-English language). FluidAudio auto-selects the Latin or
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
    /// English routes to the English-optimized EOU path; table-covered non-English
    /// languages route to Nemotron multilingual. Auto-detect (nil) and unsupported
    /// explicit languages fall back to engine-driven re-transcription when available.
    ///
    /// - Parameters:
    ///   - liveEnabled: master live-captions toggle.
    ///   - engineLanguage: the active engine's explicitly configured language
    ///     (ISO 639-1, e.g. `de`/`en`), or `nil` for auto-detect; the cloud
    ///     language while cloud transcription is on (`liveCaptionsLanguageOrNil`).
    ///   - engineSupportsLive: whether the active engine implements the
    ///     in-memory `transcribeSamples` re-transcribe hook.
    ///   - cloudTranscriptionEnabled: cloud transcription is on, so the local
    ///     engine must not be used (no `.reTranscribe`).
    static func strategy(
        liveEnabled: Bool,
        engineLanguage: String?,
        engineSupportsLive: Bool,
        cloudTranscriptionEnabled: Bool,
    ) -> Strategy {
        guard liveEnabled else { return .none }
        let fallback: Strategy = engineSupportsLive && !cloudTranscriptionEnabled ? .reTranscribe : .none
        guard let engineLanguage else { return fallback }
        guard let tag = LiveCaptionLanguages.canonicalTag(for: engineLanguage) else { return fallback }
        return tag.hasPrefix("en-") ? .englishStreaming : .nemotronStreaming
    }

    /// Whether cloud transcription is what turns captions off for this
    /// language: they would run with cloud off and do not with it on. Drives
    /// the Settings note under the live-transcription toggle.
    static func offForCloud(engineLanguage: String?, engineSupportsLive: Bool) -> Bool {
        let local = strategy(
            liveEnabled: true, engineLanguage: engineLanguage,
            engineSupportsLive: engineSupportsLive, cloudTranscriptionEnabled: false,
        )
        let cloud = strategy(
            liveEnabled: true, engineLanguage: engineLanguage,
            engineSupportsLive: engineSupportsLive, cloudTranscriptionEnabled: true,
        )
        return local != .none && cloud == .none
    }
}
