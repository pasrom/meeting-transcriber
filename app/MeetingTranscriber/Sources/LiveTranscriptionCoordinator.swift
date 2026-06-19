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
/// The active engine is supplied via `beginPrewarm(engineProvider:)` (called from
/// `AppState.init` after stored-property init, where the `[weak self]` engine
/// closure is valid) rather than captured at construction — so the coordinator
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

    private let captions: LiveCaptionsState
    private let liveEnabled: () -> Bool
    private let engineSupportsLive: () -> Bool
    private let engineLanguage: () -> String?
    private let verboseDiagnostics: () -> Bool
    private let makeController: ControllerFactory

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
    ) {
        self.captions = captions
        self.liveEnabled = liveEnabled
        self.engineSupportsLive = engineSupportsLive
        self.engineLanguage = engineLanguage
        self.verboseDiagnostics = verboseDiagnostics
        self.makeController = makeController
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
    func beginPrewarm(engineProvider: @escaping () -> (any TranscribingEngine)?) {
        self.engineProvider = engineProvider
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
        guard captionsEligible, let controller = ensureController() else { return }
        await controller.prepareForNextRecording()
        recorder.micLiveSink = controller.micSink
        recorder.appLiveSink = controller.appSink
    }

    /// Flush the live controller's pending tail utterance when recording stops.
    /// No-op when no controller is active (live transcription off / unsupported
    /// engine / never warmed). Called at STOP time — before any `prepareForNextRecording()` that
    /// clears caption state on the next recording — so the user sees the final
    /// caption of the last utterance. Idempotent: a second call after the
    /// pipelines already flushed finds nothing pending and emits nothing.
    func flush() async {
        await controller?.flush()
    }

    /// Eagerly load the VAD + engine models when the toggle is on (or already on
    /// at launch with a streaming engine) so the first utterance after the
    /// recorder starts doesn't pay the cold-load cost. Plus a re-arming
    /// `withObservationTracking` watcher on the toggle + engine setting: on every
    /// change, drop the cached controller so the next `ensureController()` rebuilds
    /// against the (possibly new) active engine and re-warms it.
    ///
    /// Engine changes take effect on the **next** recording. Switching the engine
    /// mid-recording deallocates the controller, buffers from the running recorder
    /// no longer reach any engine, and the live overlay goes silent until the next
    /// recording. Live mid-recording engine swap is a deferred follow-up.
    private func prewarmAndObserve() {
        prewarmIfEligible()
        withObservationTracking {
            // Touch the underlying settings via the gate closures so the change
            // tracker observes `liveTranscriptionEnabled` + `transcriptionEngine`
            // + the active engine's language.
            _ = liveEnabled()
            _ = engineSupportsLive()
            _ = engineLanguage()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.controller = nil
                self.prewarmAndObserve()
            }
        }
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
        Task { @MainActor in await controller.prepare() }
        return controller
    }
}
