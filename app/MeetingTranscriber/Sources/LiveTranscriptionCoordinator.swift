import Foundation
import Observation

// MARK: - LiveTranscriptionCoordinator

/// Owns the live-transcription controller lifecycle: lazy creation against the
/// active engine, the pre-warm + re-arm observer, and installing the per-channel
/// live sinks onto a recorder.
///
/// Extracted from `AppState` as a concern-specific controller (see the AppState
/// god-class split). `AppState` keeps the shared `LiveCaptionsState` (read by the
/// caption-overlay window + RPC snapshot) and injects it here; the coordinator
/// only owns the streaming `LiveTranscriptionController` and its warm-up.
///
/// The active engine + the `isRecording` probe are supplied via
/// `beginPrewarm(engineProvider:isRecording:)` (called from `AppState.init` after
/// stored-property init, where the `[weak self]` closures are valid) rather than captured at construction — so the coordinator
/// never holds an AppState back-reference. `liveEnabled` / `engineSupportsLive` /
/// `engineLanguage` / `verboseDiagnostics` are settings-backed closures.
///
/// Not `@Observable` — it exposes no observable state (it drives the controller
/// + captions imperatively). It still uses `withObservationTracking` internally
/// to watch the settings keys, which works regardless of this type's annotation.
@MainActor
final class LiveTranscriptionCoordinator {
    private var controller: LiveTranscriptionController?

    /// Source of the currently-active engine. Set by `beginPrewarm`; nil before
    /// then (so `ensureController` safely no-ops if called early). Captures the
    /// owner weakly, so it returns nil once the owner is gone.
    private var engineProvider: (() -> (any TranscribingEngine)?)?

    /// Whether a recording is currently in progress. Set by `beginPrewarm`;
    /// defaults to "not recording". Drives the mid-recording re-warm defer in
    /// `handleSettingsChange`.
    private var isRecording: () -> Bool = { false }

    /// Set when a settings change arrived during a recording and its re-warm was
    /// deferred; applied at the next idle `flush()`.
    private var needsRewarmWhenIdle = false

    /// True while `attachSinks` is mid-flight (it awaits `prepareForNextRecording()`
    /// between reading the controller and installing its sinks). The deferred
    /// re-warm in `flush()` must not swap the controller out during that window,
    /// or a fast manual stop→restart could leave the new recording feeding an
    /// orphaned controller the coordinator no longer owns.
    private var attachInFlight = false

    private let captions: LiveCaptionsState
    private let liveEnabled: () -> Bool
    private let engineSupportsLive: () -> Bool
    private let engineLanguage: () -> String?
    private let verboseDiagnostics: () -> Bool
    private let makeController: ControllerFactory

    /// Shared serial warm-up queue. The controller's `prepare()` (the heavy
    /// Nemotron / WeSpeaker load) runs through it so it doesn't compile
    /// concurrently with the ASR engine preload. Defaulted so tests get an
    /// isolated queue.
    private let warmupQueue: ModelWarmupQueue

    /// Builds the streaming controller for the (optional) active engine. The
    /// engine is nil when a language-driven streaming backend (German/English)
    /// applies with a non-streaming active engine — those sessions don't need it.
    /// Injectable so tests can supply a controller with mock collaborators (no
    /// model load); the default builds the real one. Takes `captions` +
    /// `engineLanguage` + `verboseDiagnostics` as parameters (rather than
    /// capturing `self`) so the default can be a `static` function with no
    /// init-ordering dependency.
    typealias ControllerFactory = @MainActor (
        (any StreamingTranscribingEngine)?, LiveCaptionsState, String?, @escaping () -> Bool,
    ) -> LiveTranscriptionController

    init(
        captions: LiveCaptionsState,
        liveEnabled: @escaping () -> Bool,
        engineSupportsLive: @escaping () -> Bool,
        engineLanguage: @escaping () -> String? = { nil },
        verboseDiagnostics: @escaping () -> Bool,
        makeController: @escaping ControllerFactory = LiveTranscriptionCoordinator.makeDefaultController,
        warmupQueue: ModelWarmupQueue = ModelWarmupQueue(),
    ) {
        self.captions = captions
        self.liveEnabled = liveEnabled
        self.engineSupportsLive = engineSupportsLive
        self.engineLanguage = engineLanguage
        self.verboseDiagnostics = verboseDiagnostics
        self.makeController = makeController
        self.warmupQueue = warmupQueue
    }

    private static func makeDefaultController(
        engine: (any StreamingTranscribingEngine)?,
        captions: LiveCaptionsState,
        engineLanguage: String?,
        verboseDiagnostics: @escaping () -> Bool,
    ) -> LiveTranscriptionController {
        // `verboseDiagnostics` passed labeled (not trailing): with two
        // closure-typed trailing-eligible params (`eouSessionFactory` +
        // `verboseDiagnostics`) a bare trailing closure is ambiguous, so name it.
        let verbose: () -> Bool = { verboseDiagnostics() }
        return LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            engineLanguage: engineLanguage,
            verboseDiagnostics: verbose,
        )
    }

    /// Whether live captions are eligible to run at all, per the shared gate.
    /// The language-driven streaming backends (German/English) bypass the
    /// engine-support requirement because their sessions are engine-independent.
    private var captionsEligible: Bool {
        LiveCaptionsGate.captionsAvailable(
            liveEnabled: liveEnabled(),
            engineLanguage: engineLanguage(),
            engineSupportsLive: engineSupportsLive(),
        )
    }

    /// Wire the active-engine source, then do the initial pre-warm + arm the
    /// re-warm observer. Called once from `AppState.init`.
    ///
    /// Combined into a single entry point (rather than separate prewarm + observe
    /// calls in the AppState init body) to keep that init's type-check under the
    /// 300 ms budget — the compiler's constraint solver slows with every method
    /// call inside a long initializer.
    func beginPrewarm(
        engineProvider: @escaping () -> (any TranscribingEngine)?,
        isRecording: @escaping () -> Bool = { false },
    ) {
        self.engineProvider = engineProvider
        self.isRecording = isRecording
        prewarmAndObserve()
    }

    /// Install mic + app live sinks onto `recorder` when captions are eligible.
    /// No-op otherwise — the recorder records normally with no live overlay.
    /// Called by `AppState`'s recorder factory on each recording start.
    ///
    /// `async` because `prepareForNextRecording()` awaits any in-flight stop-time
    /// flush before reusing a kept streaming session — the deterministic stop→start
    /// boundary that keeps a slow `asr.finish()` from interleaving with the next
    /// recording's ingests on the same session actor.
    func attachSinks(to recorder: DualSourceRecorder) async {
        // Existing-only: never cold-build the controller here. A cold build kicks
        // a heavy CoreML model load (Nemotron ~584 MB) from the recorder-start
        // path, landing the compile on the meeting edge and saturating the ANE /
        // compiler daemons system-wide. The controller is warmed at launch/idle
        // via `prewarmIfEligible()`; if its models are still loading its object
        // already exists (built synchronously in `ensureController` before the
        // async `prepare()`), so sinks attach and captions light up when the load
        // finishes. If it was never warmed, this recording gets no captions and
        // they come online at the next idle prewarm.
        guard captionsEligible, let controller else { return }
        attachInFlight = true
        defer { attachInFlight = false }
        await controller.prepareForNextRecording()
        recorder.micLiveSink = controller.micSink
        recorder.appLiveSink = controller.appSink
    }

    /// Flush the live controller's pending tail utterance when recording stops.
    /// No-op when no controller is active (live transcription off / unsupported
    /// engine / never warmed). Called at STOP time — before any `prepareForNextRecording()` that
    /// clears caption state on the next recording — so the user sees the final
    /// caption of the last utterance. Idempotent: a second call after the
    /// pipelines already flushed finds nothing pending and emits nothing. Also
    /// applies any re-warm deferred by a mid-recording settings change (see
    /// `handleSettingsChange`), now that we are idle.
    func flush() async {
        await controller?.flush()
        // Now idle: apply any re-warm deferred by a mid-recording settings change.
        // Skip while an `attachSinks` is mid-flight — swapping the controller then
        // would orphan the one it is binding (fast manual stop→restart).
        if needsRewarmWhenIdle, !isRecording(), !attachInFlight {
            needsRewarmWhenIdle = false
            controller = nil
            prewarmIfEligible()
        }
    }

    /// Eagerly load the VAD + engine models when the toggle is on (or already on
    /// at launch with a streaming engine) so the first utterance after the
    /// recorder starts doesn't pay the cold-load cost, then arm the settings
    /// observer.
    private func prewarmAndObserve() {
        prewarmIfEligible()
        observeSettings()
    }

    /// Arm a one-shot `withObservationTracking` watcher on the toggle + engine
    /// settings and route each change through `handleSettingsChange`.
    private func observeSettings() {
        withObservationTracking {
            // Touch the underlying settings via the gate closures so the change
            // tracker observes `liveTranscriptionEnabled` + `transcriptionEngine`
            // + the active engine's language.
            _ = liveEnabled()
            _ = engineSupportsLive()
            _ = engineLanguage()
        } onChange: { [weak self] in
            Task { @MainActor in self?.handleSettingsChange() }
        }
    }

    /// React to a toggle / engine / language change. While idle, drop the cached
    /// controller and rebuild against the new settings immediately. While a
    /// recording is in progress, DEFER: keep the current meeting's warm
    /// controller (so no CoreML recompile lands mid-recording and the overlay
    /// stays live on the current engine), re-arm the observer, and apply the
    /// rebuild at the next idle `flush()`. Either way the engine change takes
    /// effect on the next recording.
    private func handleSettingsChange() {
        guard !isRecording() else {
            needsRewarmWhenIdle = true
            observeSettings()
            return
        }
        controller = nil
        prewarmAndObserve()
    }

    private func prewarmIfEligible() {
        guard captionsEligible else { return }
        _ = ensureController()
    }

    /// Lazily create + warm the controller against the active engine. Idempotent
    /// — `prepare()` dedupes concurrent `loadModel` calls.
    ///
    /// The language-driven streaming backends (German/English) are
    /// engine-independent, so the controller is built with a nil streaming engine
    /// when the active engine doesn't conform to `StreamingTranscribingEngine`.
    /// The re-transcribe path still requires a streaming engine: it returns nil
    /// otherwise, the static equivalent of the `supportsLiveTranscription` gate
    /// (callers already check `captionsEligible`, so that nil only happens on a
    /// regression).
    private func ensureController() -> LiveTranscriptionController? {
        if let existing = controller { return existing }
        guard let engine = engineProvider?() else { return nil }
        let streamingEngine = engine as? any StreamingTranscribingEngine
        let language = engineLanguage()
        let strategy = LiveCaptionsGate.strategy(
            liveEnabled: liveEnabled(),
            engineLanguage: language,
            engineSupportsLive: engineSupportsLive(),
        )
        guard strategy != .none else { return nil }
        // Re-transcribe needs a streaming engine; the streaming backends don't.
        guard strategy != .reTranscribe || streamingEngine != nil else { return nil }
        let controller = makeController(streamingEngine, captions, language, verboseDiagnostics)
        self.controller = controller
        // Route `prepare()` through the shared warm-up queue (see `warmupQueue`).
        // Bind it locally so the fire-and-forget Task doesn't capture `self`.
        let queue = warmupQueue
        Task { @MainActor in await queue.run { await controller.prepare() } }
        return controller
    }
}
