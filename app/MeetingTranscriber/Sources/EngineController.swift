import Foundation
import Observation

// MARK: - EngineController

/// Owns the transcription-engine concern: the engine instances
/// (`WhisperKitEngine`, `ParakeetEngine`),
/// the active-engine selection, and keeping each engine's model / language /
/// vocabulary in line with `AppSettings` (both an up-front sync at construction
/// and a self-rearming reactive observer for runtime changes).
///
/// Extracted from `AppState` as the final concern-specific controller in the
/// god-class split. It syncs settings and arms its observer in `init`;
/// `AppState` then supplies queue and recording/flush probes for idle retention.
/// `AppState` exposes it as
/// `engines` and the pipeline / live-transcription coordinators read
/// `engines.activeTranscriptionEngine`; the watch-start path calls
/// `engines.syncEngineSettings()` for its belt-and-suspenders up-front sync.
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
    /// The Settings row for WhisperKit models earlier builds left in
    /// `Documents`, built once here rather than on every Settings body pass.
    let legacyWhisperModels: LegacyWhisperModelsState?

    private let settings: AppSettings
    private var queueProvider: () -> PipelineQueue? = { nil }
    private var isRecording: () -> Bool = { false }
    private var captionsUseEngine: () -> Bool = { false }
    private var previousLifetimeState: LifetimeState?
    private var pendingIdlePreferenceChange = false
    private var pendingInactiveRelease = false
    private var pendingDrain = false
    private var observationGeneration = 0

    private struct LifetimeState {
        let unloadWhenIdle: Bool
        let engine: TranscriptionEngineSetting
        let busy: Bool
        let captionsUseEngine: Bool
        let drainID: UUID?
        // Keep the previous queue until the next observation turn: a rebuild
        // must not hide a drain that occurred just before the replacement.
        let queue: PipelineQueue?
    }

    private var lifetimeState: LifetimeState {
        let queue = queueProvider()
        return LifetimeState(
            unloadWhenIdle: settings.unloadModelsWhenIdle,
            engine: settings.transcriptionEngine,
            busy: isRecording() || Self.hasWork(queue),
            captionsUseEngine: captionsUseEngine(),
            drainID: queue?.lastDrainID,
            queue: queue,
        )
    }

    private static func hasWork(_ queue: PipelineQueue?) -> Bool {
        guard let queue else { return false }
        return queue.isProcessing || !queue.pendingJobs.isEmpty || !queue.activeJobs.isEmpty
    }

    /// Shared serial warm-up queue. The launch model preload runs through it so
    /// it doesn't compile concurrently with the live-caption models (the
    /// simultaneous ANE / CoreML-compiler peak that starves the system on a
    /// meeting join). Defaulted so tests get an isolated queue.
    private let warmupQueue: ModelWarmupQueue

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

    /// Nil in the App Store build, which leaves the row out. Its `Documents` is
    /// the container's own, which iCloud does not sync, and that sync was the
    /// reason for the row; worse, a sandboxed `trashItem` moves container items
    /// into the container's private Trash, so nothing would be freed and
    /// Finder's Trash would never show them.
    private static func makeLegacyWhisperModels(settings: AppSettings) -> LegacyWhisperModelsState? {
        #if APPSTORE
            nil
        #else
            LegacyWhisperModelsState(settings: settings)
        #endif
    }

    init(settings: AppSettings, warmupQueue: ModelWarmupQueue = ModelWarmupQueue()) {
        self.settings = settings
        self.warmupQueue = warmupQueue
        self.whisperKit = Self.makeWhisperKit()
        self.parakeetEngine = Self.makeParakeet()
        self.legacyWhisperModels = Self.makeLegacyWhisperModels(settings: settings)

        // Bring engines in line with the current settings up front so the first
        // transcription doesn't run against stale defaults, then start observing
        // for runtime changes.
        syncEngineSettings()
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

    private var inactiveTranscriptionEngineState: EngineModelState {
        switch settings.transcriptionEngine {
        case .whisperKit: parakeetEngine.modelState
        case .parakeet: whisperKit.modelState
        }
    }

    /// Pre-load the active engine's model (applying its settings-derived config
    /// first) so the first transcription doesn't pay the cold-load cost. Called
    /// from the menu-bar `.task` at launch. With idle unloading on, it only
    /// downloads a model that is not on disk yet, so the first job need not.
    func preloadActiveModel(whenIdle: Bool = false) async {
        guard !settings.unloadModelsWhenIdle else {
            guard !whenIdle else { return }
            syncEngineSettings()
            await warmupQueue.run { [self] in
                switch settings.transcriptionEngine {
                case .whisperKit: await fetchTokenizer(afterDownload: whisperKit.downloadModelIfMissing())
                case .parakeet: await parakeetEngine.downloadModelIfMissing()
                }
            }
            return
        }
        // Push settings into the active engine through the one canonical sync
        // (idempotent — it already ran at init), then load it. Routing the
        // variant/language writes through `syncEngineSettings` keeps a single
        // settings→engine path instead of re-inlining a whisperKit-only subset.
        syncEngineSettings()
        // Serialize against the live-caption model warm-up so the two big CoreML
        // loads don't compile at once. `run` awaits the load, so the caller still
        // returns only after the model is loaded.
        await warmupQueue.run { [self] in
            guard !settings.unloadModelsWhenIdle else { return }
            guard !whenIdle || !lifetimeState.busy else {
                pendingIdlePreferenceChange = true
                return
            }
            // loadModel() rebuilds unconditionally; a toggle flip may find it loaded.
            guard activeTranscriptionEngine.modelState != .loaded else { return }
            await activeTranscriptionEngine.loadModel()
        }
    }

    /// WhisperKit fetches its tokenizer only during a load, so a fresh download
    /// is loaded once while the machine is online, then released if still idle.
    private func fetchTokenizer(afterDownload downloaded: Bool) async {
        guard downloaded else { return }
        if whisperKit.modelState != .loaded { await whisperKit.loadModel() }
        let state = lifetimeState
        if state.unloadWhenIdle, state.engine == .whisperKit, !state.busy, !state.captionsUseEngine {
            whisperKit.releaseModel()
        }
    }

    /// Push current model / language / vocabulary settings into the active
    /// engine. Idempotent — each branch only writes when the value actually
    /// differs, so unchanged settings don't churn the engine's `@Observable`
    /// watchers (`applyModelVariant` self-guards the same way).
    func syncEngineSettings() {
        defer { updateModelLifetime() }
        switch settings.transcriptionEngine {
        case .whisperKit:
            let model = settings.whisperKitModelSelection
            whisperKit.applyModelVariant(model.variant, origin: model.origin)
            let next = settings.whisperLanguageOrNil
            if whisperKit.language != next { whisperKit.language = next }
            let nextVocab = settings.customVocabularyPath
            if whisperKit.customVocabularyPath != nextVocab { whisperKit.customVocabularyPath = nextVocab }
            let nextBookmark = settings.customVocabularyBookmark
            if whisperKit.customVocabularyBookmark != nextBookmark { whisperKit.customVocabularyBookmark = nextBookmark }
            let nextVocabularyPromptEnabled = settings.customVocabularyEnabled
            if whisperKit.vocabularyPromptEnabled != nextVocabularyPromptEnabled {
                whisperKit.vocabularyPromptEnabled = nextVocabularyPromptEnabled
            }

        case .parakeet:
            let vocabularyOn = settings.customVocabularyEnabled
            let nextVocab = vocabularyOn ? settings.customVocabularyPath : ""
            if parakeetEngine.customVocabularyPath != nextVocab { parakeetEngine.customVocabularyPath = nextVocab }
            let nextBookmark = vocabularyOn ? settings.customVocabularyBookmark : nil
            if parakeetEngine.customVocabularyBookmark != nextBookmark { parakeetEngine.customVocabularyBookmark = nextBookmark }
            let nextLang = settings.parakeetLanguageOrNil
            if parakeetEngine.language != nextLang { parakeetEngine.language = nextLang }
        }
    }

    func activateModelLifetime(
        queue: @escaping () -> PipelineQueue?,
        isRecording: @escaping () -> Bool,
        captionsUseEngine: @escaping () -> Bool = { false },
    ) {
        queueProvider = queue
        self.isRecording = isRecording
        self.captionsUseEngine = captionsUseEngine
        syncEngineSettings()
        observeEngineSettings()
    }

    private func updateModelLifetime() {
        let current = lifetimeState
        let previous = previousLifetimeState
        previousLifetimeState = current
        guard let previous else { return }
        pendingIdlePreferenceChange = pendingIdlePreferenceChange || previous.unloadWhenIdle != current.unloadWhenIdle
        pendingInactiveRelease = pendingInactiveRelease || previous.engine != current.engine
        let priorQueueDrained = previous.queue?.lastDrainID != nil && previous.queue?.lastDrainID != previous.drainID
        pendingDrain = pendingDrain || priorQueueDrained || (current.drainID != nil && previous.drainID != current.drainID)
        guard !current.busy else { return }

        // A queue and a recording's captions can still use the previous engine.
        // Retire it only after their work (including the caption tail) finishes.
        // Off keeps it: the queue runs on its engine until it is rebuilt.
        if current.unloadWhenIdle,
           pendingInactiveRelease || previous.busy || pendingDrain || inactiveTranscriptionEngineState != .unloaded {
            switch current.engine {
            case .whisperKit: parakeetEngine.releaseModel()
            case .parakeet: whisperKit.releaseModel()
            }
            pendingInactiveRelease = false
        }
        if current.unloadWhenIdle,
           previous.busy || pendingDrain || pendingIdlePreferenceChange || (previous.captionsUseEngine && !current.captionsUseEngine) {
            if !current.captionsUseEngine {
                switch current.engine {
                case .whisperKit: whisperKit.releaseModel()
                case .parakeet: parakeetEngine.releaseModel()
                }
            }
            queueProvider()?.vad = nil
            if priorQueueDrained { previous.queue?.vad = nil }
        } else if !current.unloadWhenIdle, pendingIdlePreferenceChange {
            Task { [weak self] in await self?.preloadActiveModel(whenIdle: true) }
        }
        pendingIdlePreferenceChange = false
        pendingDrain = false
    }

    /// `withObservationTracking` is one-shot — re-arm after each fire so the
    /// controller reacts to every settings change, not just the first one.
    /// Same self-re-arming pattern the other concern controllers use.
    private func observeEngineSettings() {
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            _ = lifetimeState
            // A pre-switch caption warm-up may still be queued. If it loads the
            // retired engine later, release it too; never observe the active
            // model here, so an explicit Load Model remains effective.
            // A stale warm-up on the active engine keeps its load until the next drain.
            _ = inactiveTranscriptionEngineState
            _ = settings.transcriptionEngine
            _ = settings.whisperKitModel
            _ = settings.whisperKitCustomModelEnabled
            _ = settings.whisperKitCustomRepo
            _ = settings.whisperKitCustomVariant
            _ = settings.whisperKitCustomModelFolderPath
            _ = settings.whisperKitCustomModelFolderBookmark
            _ = settings.whisperLanguage
            _ = settings.customVocabularyPath
            _ = settings.customVocabularyBookmark
            _ = settings.customVocabularyEnabled
            _ = settings.parakeetLanguage
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.observationGeneration else { return }
                self.syncEngineSettings()
                self.observeEngineSettings()
            }
        }
    }
}
