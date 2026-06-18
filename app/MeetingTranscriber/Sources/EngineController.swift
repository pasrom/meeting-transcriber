import Foundation
import Observation

// MARK: - EngineController

/// Owns the transcription-engine concern: the engine instances
/// (`WhisperKitEngine`, `ParakeetEngine`),
/// the active-engine selection, and keeping each engine's language / vocabulary
/// in line with `AppSettings` (both an up-front sync at construction and a
/// self-rearming reactive observer for runtime changes).
///
/// Extracted from `AppState` as the final concern-specific controller in the
/// god-class split. Unlike the other controllers it is fully self-contained — it
/// needs only `settings`, so it does its up-front sync + arms its observer in its
/// own `init` (no post-init `activate` wiring). `AppState` exposes it as
/// `engines` and the pipeline / live-transcription coordinators read
/// `engines.activeTranscriptionEngine`; the watch-start path calls
/// `engines.syncLanguageSettings()` for its belt-and-suspenders up-front sync.
///
/// Not `@Observable` — its stored engine references are `let`s and consumers
/// observe the engine instances themselves (each is `@Observable`), so the
/// controller exposes no observable state of its own. It still uses
/// `withObservationTracking` internally to watch the settings keys, which works
/// regardless of this type's annotation (same as `LiveTranscriptionCoordinator`).
@MainActor
final class EngineController {
    let whisperKit: WhisperKitEngine
    let parakeetEngine: ParakeetEngine

    private let settings: AppSettings

    // Dependency-default factories keep `init`'s body-type-check under the 300 ms
    // budget — an inline `@Observable` engine constructor forces the type-checker
    // to re-solve that engine's own init constraints at this call site (the same
    // reason AppState uses factory helpers for its defaults).

    private static func makeWhisperKit() -> WhisperKitEngine {
        WhisperKitEngine()
    }

    private static func makeParakeet() -> ParakeetEngine {
        ParakeetEngine()
    }

    init(settings: AppSettings) {
        self.settings = settings
        self.whisperKit = Self.makeWhisperKit()
        self.parakeetEngine = Self.makeParakeet()

        // Bring engines in line with the current settings up front so the first
        // transcription doesn't run against stale defaults, then start observing
        // for runtime changes.
        syncLanguageSettings()
        observeEngineSettings()
    }

    /// The active transcription engine based on the current settings.
    var activeTranscriptionEngine: any TranscribingEngine {
        switch settings.transcriptionEngine {
        case .parakeet:
            parakeetEngine

        case .whisperKit:
            whisperKit
        }
    }

    /// Pre-load the active engine's model (applying its settings-derived config
    /// first) so the first transcription doesn't pay the cold-load cost. Called
    /// from the menu-bar `.task` at launch.
    func preloadActiveModel() async {
        switch settings.transcriptionEngine {
        case .whisperKit:
            whisperKit.modelVariant = settings.whisperKitModel
            whisperKit.language = settings.whisperLanguageOrNil
            await whisperKit.loadModel()

        case .parakeet:
            await parakeetEngine.loadModel()
        }
    }

    /// Push current language/vocabulary settings into the active engine.
    /// Idempotent — each branch only writes when the value actually differs,
    /// so unchanged settings don't churn the engine's `@Observable` watchers.
    func syncLanguageSettings() {
        switch settings.transcriptionEngine {
        case .whisperKit:
            let next = settings.whisperLanguageOrNil
            if whisperKit.language != next { whisperKit.language = next }

        case .parakeet:
            let nextVocab = settings.customVocabularyPath
            if parakeetEngine.customVocabularyPath != nextVocab { parakeetEngine.customVocabularyPath = nextVocab }
            let nextLang = settings.parakeetLanguageOrNil
            if parakeetEngine.language != nextLang { parakeetEngine.language = nextLang }
        }
    }

    /// `withObservationTracking` is one-shot — re-arm after each fire so the
    /// controller reacts to every settings change, not just the first one.
    /// Same self-re-arming pattern the other concern controllers use.
    private func observeEngineSettings() {
        withObservationTracking {
            _ = settings.transcriptionEngine
            _ = settings.whisperLanguage
            _ = settings.customVocabularyPath
            _ = settings.parakeetLanguage
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncLanguageSettings()
                self.observeEngineSettings()
            }
        }
    }
}
