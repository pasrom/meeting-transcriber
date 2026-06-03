import Foundation
import Observation

// MARK: - PipelineController

/// Owns the post-processing pipeline concern: the `PipelineQueue` instance, its
/// construction from the current settings + active engine, the per-job
/// notification callbacks, and the file-enqueue entry points.
///
/// Extracted from `AppState` as a concern-specific controller (see the AppState
/// god-class split). `AppState` keeps the engine instances + the active-engine
/// switch and supplies the active engine via `activate(engineProvider:)` (called
/// post stored-property init, where the `[weak self]` engine closure is valid) so
/// this controller never holds an `AppState` back-reference. `settings` +
/// `notifier` are shared references injected at construction.
///
/// `@Observable` because `queue` is read by the menu-bar UI + RPC snapshot: when
/// `rebuild()` swaps in a freshly-wired queue, the views observing `queue`
/// through `AppState.pipeline.queue` must re-read. Nested-`@Observable`
/// observation through `let pipeline` + this stored `var queue` is the same
/// pattern the other extracted controllers use.
@Observable
@MainActor
final class PipelineController {
    /// The active pipeline queue. Settable so tests can swap in a queue wired to
    /// an isolated `logDir` (byte-equivalent to the prior `AppState.pipelineQueue`
    /// var, which was likewise publicly settable). Production mutates it only via
    /// `rebuild()` / `ensureQueue()`.
    var queue: PipelineQueue

    private let settings: AppSettings
    private let notifier: any AppNotifying

    /// Source of the currently-active engine. Set by `activate`; nil before then
    /// (so `makeQueue()` safely returns the current queue if called early — only
    /// reachable at process teardown, since `rebuild`/`ensureQueue` are driven by
    /// user actions while `AppState` is alive). Captures the owner weakly.
    private var engineProvider: (() -> (any TranscribingEngine)?)?

    init(settings: AppSettings, notifier: any AppNotifying) {
        self.settings = settings
        self.notifier = notifier
        self.queue = PipelineQueue()
    }

    /// Wire the active-engine source. Called once from `AppState.init` after its
    /// stored-property init.
    func activate(engineProvider: @escaping () -> (any TranscribingEngine)?) {
        self.engineProvider = engineProvider
    }

    // MARK: - Queue lifecycle

    /// Rebuild the queue against the current settings + active engine and
    /// re-install the job-state callbacks. Unconditional — the watch-start path
    /// always rebuilds so a fresh session picks up the latest settings/engine.
    func rebuild() {
        queue = makeQueue()
        configureCallbacks()
    }

    /// Rebuild only when the queue isn't already wired to an engine. The
    /// manual-recording + file-enqueue paths call this so an already-configured
    /// queue (e.g. one a test injected) isn't replaced.
    func ensureQueue() {
        guard queue.engine == nil else { return }
        rebuild()
    }

    /// One-stop wired `PipelineQueue`: active engine from the provider, the
    /// diarization/protocol factories, current settings, then load the persisted
    /// snapshot + recover orphaned recordings off-main + refresh known names.
    func makeQueue() -> PipelineQueue {
        guard let engine = engineProvider?() else { return queue }
        let q = PipelineQueue(
            engine: engine,
            diarizationFactory: { [self] in makeFluidDiarizer(mode: settings.diarizerMode) },
            diarizationFactoryWithMode: { [self] mode in makeFluidDiarizer(mode: mode) },
            protocolGeneratorFactory: { [self] in makeProtocolGenerator() },
            outputDir: settings.effectiveOutputDir,
            diarizeEnabled: settings.diarize,
            numSpeakers: settings.numSpeakers,
            micLabel: settings.micName,
            speakerMatcherFactory: { SpeakerMatcher() },
            vadConfig: settings.vadEnabled ? VADConfig(threshold: settings.vadThreshold) : nil,
            recognitionStatsLog: RecognitionStatsLog(),
        )
        q.loadSnapshot()
        // Fire-and-forget: dir scan + per-file attr probes run off-main so app
        // startup (and the first call to `enqueueFiles`) isn't blocked by a slow
        // filesystem. Recovered jobs appear in `queue.jobs` once the scan returns.
        Task { await q.recoverOrphanedRecordings() }
        q.refreshKnownSpeakerNames()
        return q
    }

    /// One-stop FluidDiarizer instantiation. Captures the current tuning fields
    /// from settings so both the global-mode factory and the per-job
    /// mode-override factory stay in sync. Tuning only affects `.offline` mode,
    /// but is harmless when passed to `.sortformer`.
    private func makeFluidDiarizer(mode: DiarizerMode) -> FluidDiarizer {
        FluidDiarizer(
            mode: mode,
            tuning: OfflineDiarizerTuning(
                clusterThreshold: settings.clusterThreshold,
                warmStartFa: settings.warmStartFa,
                warmStartFb: settings.warmStartFb,
                minSegmentDurationSeconds: settings.minSegmentDurationSeconds,
                excludeOverlap: settings.excludeOverlap,
            ),
        )
    }

    // `makeProtocolGenerator` + `configureCallbacks` are module-internal (not
    // `private`) to preserve the access level they had on `AppState` before this
    // extraction — they encode real behavior (provider selection, notification
    // routing) that is unit-tested directly, same altitude as the other wiring
    // methods above.
    func makeProtocolGenerator() -> (any ProtocolGenerating)? {
        switch settings.protocolProvider {
        #if !APPSTORE
            case .claudeCLI:
                ClaudeCLIProtocolGenerator(claudeBin: settings.claudeBin, language: settings.protocolLanguage)
        #endif

        case .openAICompatible:
            OpenAIProtocolGenerator(
                endpoint: URL(string: settings.openAIEndpoint)
                    // swiftlint:disable:next force_unwrapping
                    ?? URL(string: "http://localhost:11434/v1/chat/completions")!,
                model: settings.openAIModel,
                language: settings.protocolLanguage,
                apiKey: settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey,
            )

        case .none:
            nil
        }
    }

    func configureCallbacks() {
        queue.onJobStateChange = { [notifier] job, _, newState in
            switch newState {
            case .done:
                let title = job.protocolPath != nil ? "Protocol Ready" : "Transcript Saved"
                notifier.notify(title: title, body: job.meetingTitle)

            case .error:
                if let err = job.error {
                    notifier.notify(title: "Error", body: err)
                }

            default:
                break
            }
        }
    }

    // MARK: - File enqueue

    /// Filters `urls` to files that currently exist on disk, forwards them to
    /// `enqueueFiles`, and returns the existing count. RPC-friendly entry point.
    @discardableResult
    func enqueueExistingFiles(_ urls: [URL]) -> Int {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return 0 }
        enqueueFiles(existing)
        return existing.count
    }

    func enqueueFiles(_ urls: [URL]) {
        ensureQueue()

        let resolution = PairedRecordingResolver.resolve(urls: urls)

        for group in resolution.paired {
            let sidecar = RecordingSidecar.read(
                fromDirectory: group.directory,
                basename: group.stem,
            )
            let title = sidecar?.title ?? group.stem
            let appName = sidecar?.appName ?? "File"
            let micDelay = sidecar?.micDelaySeconds ?? 0
            let participants = sidecar?.participants ?? []

            // For paired groups: pass `group.mix` directly (nil when only app+mic
            // were selected — the pipeline mixes app+mic into the workdir cache
            // on the fly, no persistent `_mix.wav` is written to the user's
            // recordings dir).
            let job = PipelineJob(
                meetingTitle: title, appName: appName,
                mixPath: group.mix, appPath: group.app, micPath: group.mic,
                micDelay: micDelay, participants: participants,
            )
            queue.enqueue(job)
        }

        for url in resolution.singletons {
            let title = url.deletingPathExtension().lastPathComponent
            let job = PipelineJob(
                meetingTitle: title,
                appName: "File",
                mixPath: url,
                appPath: nil,
                micPath: nil,
                micDelay: 0,
            )
            queue.enqueue(job)
        }
    }
}
