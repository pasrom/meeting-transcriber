import CoreML
import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveSpeakerMatcher")

/// Protocol-injection seam so `LiveTranscriptionController` can take a
/// fake matcher in tests (returns canned names without loading a real
/// CoreML model). Production binds the real `LiveSpeakerMatcher`.
protocol LiveSpeakerMatching: Sendable {
    /// Pre-warm any backing model state. Idempotent.
    func prepare() async throws
    /// The matched speaker, or none if no enrolled voice passes the matcher's
    /// threshold + confidence margin.
    func match(audio: [Float]) async -> LiveSpeakerMatch
    /// The closest enrolled voice of a short window, for `VoiceChangeDetector`; `.unknown` unless
    /// the model is already loaded and two or more voices are enrolled. Never loads the model.
    func probe(audio: [Float]) async -> LiveSpeakerMatch
}

struct LiveSpeakerMatch: Equatable, Sendable {
    /// Set when an enrolled voice passes threshold and margin.
    var name: String?
    /// The closest enrolled voice, when it lies within `nearestSlack` of the match threshold.
    var nearest: String?
    /// Set by `probe` only: the closest enrolled voice at any distance, for `VoiceChangeDetector`,
    /// which applies its own bound.
    var closest: String?
    /// Distance to `closest`.
    var distance: Float?
    /// How much farther the runner-up is; nil with a single enrolled voice.
    var margin: Float?

    static let unknown = Self()

    /// Farther than this past the threshold, the line may be a voice nobody enrolled, so no voice is
    /// nearest; unbounded, a guest took the only enrolled speaker's name.
    static let nearestSlack: Float = 0.05
}

extension LiveSpeakerMatch {
    /// `sentinel` is the label the match was run under; the matcher echoes it back when no voice passes.
    init(_ result: SpeakerMatcher.VerboseMatch, sentinel: String, threshold: Float) {
        let candidates = result.topCandidates
        self.init(
            name: result.assignedName == sentinel ? nil : result.assignedName,
            nearest: candidates.first.flatMap { $0.hybrid < threshold + Self.nearestSlack ? $0.name : nil },
        )
    }

    /// A probe's result from each enrolled voice's distance: the closest and its lead over the
    /// runner-up; `.unknown` with fewer than two voices.
    init(probing distances: [(name: String, distance: Float)]) {
        let scored = distances.sorted { $0.distance < $1.distance }
        guard scored.count >= 2 else {
            self = .unknown
            return
        }
        self.init(closest: scored[0].name, distance: scored[0].distance, margin: scored[1].distance - scored[0].distance)
    }
}

/// Live speaker matching for the caption overlay. Given the speech samples
/// behind a finalized utterance, extracts a WeSpeaker embedding and matches
/// it against the enrolled `speakers.json` registry — same model + matcher
/// the batch pipeline uses, so a voice enrolled via the post-meeting naming
/// dialog gets recognised live without retraining.
///
/// Off-MainActor (actor isolation) so the CoreML inference doesn't stall
/// the UI. `prepare()` is idempotent and deduped via a single-flight task —
/// concurrent callers await the first's work. This is the typed/throwing
/// variant (like `FluidVAD.ensureManager()`); the engines' simpler
/// non-throwing `loadModel()` dedup is factored into `SingleFlight`.
///
/// **Vector-space note:** Both the batch path
/// (`FluidDiarizer.extractSortformerEmbeddings`) and this live path load
/// the same `wespeaker_v2` CoreML model via
/// `FluidOfflineProcessor.loadDiarizerModels(computeUnits:)`. The
/// embeddings are byte-for-byte compatible with anything already in
/// `speakers.json` — no re-enrollment needed when this ships.
///
/// **Cold-start optimisation:** The first call to `prepare()` ever made on
/// a given installation loads the full `DiarizerModels` (both segmentation
/// + embedding), reads the WeSpeaker mask frame count from the
/// segmentation model's output shape, and persists that integer to
/// `UserDefaults`. Every subsequent launch loads only the embedding model
/// and reads the cached frame count — saving ~300–500 ms cold-start
/// + ~150 MB resident RAM after the first use. The cache key includes
/// `ModelNames.Diarizer.segmentationFile` so a FluidAudio model rename
/// (the likely failure mode) invalidates the cache automatically.
actor LiveSpeakerMatcher: LiveSpeakerMatching {
    /// `UserDefaults` key for the cached WeSpeaker mask frame count.
    /// Includes the FluidAudio segmentation model filename so a rename
    /// (e.g. `pyannote_segmentation` → `pyannote_segmentation_v4`)
    /// changes the key and the cache miss fires a fresh derivation
    /// against the new model. Residual risk: same-filename-different-
    /// content updates aren't detected here — `LiveTranscriptionE2ETests`
    /// covers that case end-to-end (a wrong frame count produces
    /// zero-embeddings → no matches → all-fallback labels).
    private static let cachedFrameCountKey =
        "LiveSpeakerMatcher.weSpeakerFrameCount.\(ModelNames.Diarizer.segmentationFile)"

    /// Compute units for the WeSpeaker embedding model. Shared with the
    /// offline pipeline, which keeps this model off the GPU because Core ML's
    /// `.all` routing can abort the process inside MPSGraph (see
    /// `FluidOfflineProcessor.computeUnits`). Not conditional on CI, so the
    /// test suite exercises the configuration that ships.
    static let embeddingComputeUnits = FluidOfflineProcessor.computeUnits

    /// SpeakerMatcher is a class with internal NSLock-based DB
    /// serialization — safe to call from any thread. Held by reference so
    /// rename / delete operations made via the existing UI (KnownVoices)
    /// don't require us to rebuild the matcher.
    private let speakerMatcher: SpeakerMatcher

    /// Closure-injection for the frame-count cache. Production wires the
    /// default reader/writer pair backed by `UserDefaults.standard`; tests
    /// inject in-memory closures so they don't share state with each
    /// other or with the running app. `@Sendable` so the closures can
    /// cross the actor isolation boundary from any caller.
    private let readCachedFrameCount: @Sendable () -> Int?
    private let writeCachedFrameCount: @Sendable (Int) -> Void

    /// The two FluidAudio load calls, one per launch path, each handed the
    /// compute units to load with. Injectable so tests can see which units
    /// each path asks for without loading a model.
    struct ModelLoaders: Sendable {
        /// Cache hit: the embedding model alone.
        var embeddingModel: @Sendable (MLComputeUnits) async throws -> MLModel
        /// Cache miss: segmentation + embedding, to derive the frame count.
        var diarizerModels: @Sendable (MLComputeUnits) async throws -> DiarizerModels

        static let fluidAudio = ModelLoaders(
            embeddingModel: { computeUnits in
                // `DiarizerModels.defaultModelsDirectory()` returns the
                // model-bundle dir (`…/Models/diarizer-coreml`); `ModelHub`
                // appends `repo.folderName` itself, so we strip the trailing
                // component to give it the parent (`…/Models`).
                let modelsByName = try await ModelHub.loadModels(
                    .diarizer,
                    modelNames: [ModelNames.Diarizer.embeddingFile],
                    directory: DiarizerModels.defaultModelsDirectory().deletingLastPathComponent(),
                    computeUnits: computeUnits,
                )
                guard let model = modelsByName[ModelNames.Diarizer.embeddingFile] else {
                    throw LiveSpeakerMatcherError.modelLoadFailed
                }
                return model
            },
            diarizerModels: { computeUnits in
                try await FluidOfflineProcessor.loadDiarizerModels(computeUnits: computeUnits)
            },
        )
    }

    private let modelLoaders: ModelLoaders

    /// Loaded lazily on first `prepare()`. Subsequent calls await the same
    /// task. Cleared on failure so a transient model-download error doesn't
    /// latch every future caller.
    private var loadedModels: LoadedModels?
    private var loadingTask: Task<LoadedModels, any Error>?
    /// Enrolled voices as of the last load or line match; probes read this instead of `speakers.json`.
    private var probeVoices: [StoredSpeaker] = []

    /// `EmbeddingExtractor` is a FluidAudio reference type without declared
    /// `Sendable` conformance. The loader Task constructs it once and hands
    /// the value back to the actor's storage; after that it's only accessed
    /// from inside actor-isolated methods. `@unchecked Sendable` is the
    /// "verified the Task → actor crossing" marker Swift 6 requires.
    private struct LoadedModels: @unchecked Sendable {
        let extractor: EmbeddingExtractor
        /// All-ones single-speaker mask pre-allocated once per session.
        /// Live matching always supplies a single speaker, so the mask is
        /// constant for the lifetime of `LoadedModels` — caching avoids a
        /// `~1.5 KB` re-allocation on every finalized utterance.
        let allOnesMask: [[Float]]
    }

    init(
        speakerMatcher: SpeakerMatcher = SpeakerMatcher(),
        readCachedFrameCount: @escaping @Sendable () -> Int? = LiveSpeakerMatcher.defaultReadCachedFrameCount,
        writeCachedFrameCount: @escaping @Sendable (Int) -> Void = LiveSpeakerMatcher.defaultWriteCachedFrameCount,
        modelLoaders: ModelLoaders = .fluidAudio,
    ) {
        self.speakerMatcher = speakerMatcher
        self.readCachedFrameCount = readCachedFrameCount
        self.writeCachedFrameCount = writeCachedFrameCount
        self.modelLoaders = modelLoaders
    }

    /// Production reader: `UserDefaults.standard.integer(forKey:)` returns
    /// 0 for missing keys, so we distinguish "absent" from "cached 0"
    /// (which would be invalid anyway: a zero frame count produces
    /// zero-length masks).
    @Sendable
    private static func defaultReadCachedFrameCount() -> Int? {
        let value = UserDefaults.standard.integer(forKey: cachedFrameCountKey)
        return value > 0 ? value : nil
    }

    @Sendable
    private static func defaultWriteCachedFrameCount(_ value: Int) {
        UserDefaults.standard.set(value, forKey: cachedFrameCountKey)
    }

    /// Warm the embedding model. On the very first call ever made on this
    /// installation, also loads the segmentation model once to derive +
    /// cache the WeSpeaker mask frame count. Safe to call multiple times
    /// — deduped via single-flight `loadingTask`.
    func prepare() async throws {
        if loadedModels != nil { return }
        if let existing = loadingTask {
            _ = try await existing.value
            return
        }
        let task = Task<LoadedModels, any Error> {
            try await self.loadModels()
        }
        loadingTask = task
        do {
            loadedModels = try await task.value
            loadingTask = nil
            probeVoices = speakerMatcher.matchableSpeakers()
        } catch {
            loadingTask = nil
            throw error
        }
    }

    /// Match `audio` against the enrolled speaker DB. The result names the
    /// speaker when the embedding passes the threshold + confidence margin
    /// (caller falls back to a channel default otherwise). Errors during
    /// embedding extraction also return `.unknown` so a transient inference
    /// failure degrades to "unknown speaker" rather than blocking the caption.
    func match(audio: [Float]) async -> LiveSpeakerMatch {
        do {
            try await prepare()
        } catch {
            logger.warning("model load failed, falling back to channel default: \(error.localizedDescription, privacy: .public)")
            return .unknown
        }
        guard let models = loadedModels else { return .unknown }

        // Extractor pads / loops the audio internally to its 160 000-sample
        // window — short utterances are stretched, not truncated.
        let embedding: [Float]
        do {
            let embs = try models.extractor.getEmbeddings(audio: audio, masks: models.allOnesMask)
            guard let first = embs.first, !first.allSatisfy({ $0 == 0 }) else {
                // Extractor returns a zero vector for inactive speakers (mask
                // activity below threshold). Shouldn't happen for an all-ones
                // mask on real speech, but degrade gracefully if it does.
                return .unknown
            }
            embedding = first
        } catch {
            logger.warning("embedding extraction failed: \(error.localizedDescription, privacy: .public)")
            return .unknown
        }

        // `SpeakerMatcher` returns the input label verbatim when no
        // candidate clears threshold + margin (label-as-fallback). A fixed
        // sentinel string would collide if a user enrolled a speaker with
        // the same name. Per-call UUID guarantees no collision with any
        // user-chosen name in `speakers.json`.
        let sentinel = UUID().uuidString
        probeVoices = speakerMatcher.matchableSpeakers()
        guard let result = speakerMatcher.matchVerbose(embeddings: [sentinel: embedding], against: probeVoices)[sentinel]
        else { return .unknown }
        return LiveSpeakerMatch(result, sentinel: sentinel, threshold: speakerMatcher.threshold)
    }

    /// With fewer than two voices the closest is always the same one, so no change can be found.
    func probe(audio: [Float]) -> LiveSpeakerMatch {
        guard probeVoices.count >= 2, let models = loadedModels,
              let embedding = try? models.extractor.getEmbeddings(audio: audio, masks: models.allOnesMask).first,
              !embedding.allSatisfy({ $0 == 0 })
        else { return .unknown }
        return LiveSpeakerMatch(probing: probeVoices.map { voice in
            (name: voice.name, distance: SpeakerMatcher.distance(query: embedding, speaker: voice))
        })
    }

    private func loadModels() async throws -> LoadedModels {
        let computeUnits = Self.embeddingComputeUnits

        if let cachedFrameCount = readCachedFrameCount() {
            // Cache hit: load only the embedding model. The savings vs.
            // the first-launch path are documented in the type docstring.
            let embeddingModel = try await modelLoaders.embeddingModel(computeUnits)
            logger.info("WeSpeaker loaded for live matching (cached frameCount=\(cachedFrameCount, privacy: .public), segmentation skipped)")
            return makeLoadedModels(embeddingModel: embeddingModel, frameCount: cachedFrameCount)
        }

        // First-ever launch (or cache invalidated by FluidAudio rename):
        // load the full DiarizerModels so we can query the segmentation
        // model's `segments` output shape — `segShape[1]` is the WeSpeaker
        // mask frame count. Persist it so future launches take the
        // embedding-only fast path above.
        let full = try await modelLoaders.diarizerModels(computeUnits)
        guard
            let segShape = full.segmentationModel.modelDescription
                .outputDescriptionsByName["segments"]?.multiArrayConstraint?.shape,
            segShape.count >= 2
        else {
            throw LiveSpeakerMatcherError.modelShapeUnavailable
        }
        let frameCount = segShape[1].intValue
        writeCachedFrameCount(frameCount)
        logger.info("WeSpeaker loaded for live matching (first-launch, derived frameCount=\(frameCount, privacy: .public))")
        return makeLoadedModels(embeddingModel: full.embeddingModel, frameCount: frameCount)
    }

    private func makeLoadedModels(embeddingModel: MLModel, frameCount: Int) -> LoadedModels {
        let extractor = EmbeddingExtractor(embeddingModel: embeddingModel)
        let mask: [[Float]] = [[Float](repeating: 1.0, count: frameCount)]
        return LoadedModels(extractor: extractor, allOnesMask: mask)
    }
}

enum LiveSpeakerMatcherError: Error {
    case modelLoadFailed
    case modelShapeUnavailable
}
