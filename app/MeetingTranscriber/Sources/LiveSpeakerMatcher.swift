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
    /// Returns a matched speaker name, or `nil` if no enrolled voice
    /// passes the matcher's threshold + confidence margin.
    func match(audio: [Float]) async -> String?
}

/// Live speaker matching for the caption overlay. Given the speech samples
/// behind a finalized utterance, extracts a WeSpeaker embedding and matches
/// it against the enrolled `speakers.json` registry — same model + matcher
/// the batch pipeline uses, so a voice enrolled via the post-meeting naming
/// dialog gets recognised live without retraining.
///
/// Off-MainActor (actor isolation) so the CoreML inference doesn't stall
/// the UI. `prepare()` is idempotent and deduped via a single-flight task
/// in the same shape as `WhisperKitEngine.loadModel()` /
/// `ParakeetEngine.loadModel()` / `FluidVAD.ensureManager()` — second
/// caller awaits the first's work.
///
/// **Vector-space note:** Both the batch path
/// (`FluidDiarizer.extractSortformerEmbeddings`) and this live path load
/// the same `wespeaker_v2` CoreML model via `DiarizerModels.load()`. The
/// embeddings are byte-for-byte compatible with anything already in
/// `speakers.json` — no re-enrollment needed when this ships.
actor LiveSpeakerMatcher: LiveSpeakerMatching {
    /// SpeakerMatcher is a class with internal NSLock-based DB
    /// serialization — safe to call from any thread. Held by reference so
    /// rename / delete operations made via the existing UI (KnownVoices)
    /// don't require us to rebuild the matcher.
    private let speakerMatcher: SpeakerMatcher

    /// Loaded lazily on first `prepare()`. Subsequent calls await the same
    /// task. Cleared on failure so a transient model-download error doesn't
    /// latch every future caller (mirrors
    /// [[feedback-single-flight-clear-loadingtask-on-failure]]).
    private var loadedModels: LoadedModels?
    private var loadingTask: Task<LoadedModels, any Error>?

    /// `EmbeddingExtractor` is a FluidAudio reference type without declared
    /// `Sendable` conformance. The loader Task constructs it once and hands
    /// the value back to the actor's storage; after that it's only accessed
    /// from inside actor-isolated methods. `@unchecked Sendable` is the
    /// "verified the Task → actor crossing" marker Swift 6 requires.
    private struct LoadedModels: @unchecked Sendable {
        let extractor: EmbeddingExtractor
        /// Frame count expected by the WeSpeaker model's mask input.
        /// Queried from the companion segmentation model's output shape so a
        /// future FluidAudio model swap doesn't silently mis-shape masks.
        let weSpeakerFrameCount: Int
        /// All-ones single-speaker mask pre-allocated once per session.
        /// Live matching always supplies a single speaker, so the mask is
        /// constant for the lifetime of `LoadedModels` — caching avoids a
        /// `~1.5 KB` re-allocation on every finalized utterance.
        let allOnesMask: [[Float]]
    }

    init(speakerMatcher: SpeakerMatcher = SpeakerMatcher()) {
        self.speakerMatcher = speakerMatcher
    }

    /// Load the WeSpeaker + companion segmentation models. Safe to call
    /// multiple times — deduped via single-flight `loadingTask`. Called by
    /// `LiveTranscriptionController.prepare()` so the first live final in
    /// a recording doesn't pay the ~500 ms cold-load latency.
    func prepare() async throws {
        if loadedModels != nil { return }
        if let existing = loadingTask {
            _ = try await existing.value
            return
        }
        let task = Task<LoadedModels, any Error> {
            try await Self.loadModels()
        }
        loadingTask = task
        do {
            loadedModels = try await task.value
            loadingTask = nil
        } catch {
            loadingTask = nil
            throw error
        }
    }

    /// Match `audio` against the enrolled speaker DB. Returns the matched
    /// speaker name when the embedding passes the threshold + confidence
    /// margin, or `nil` when it doesn't (caller falls back to a channel
    /// default). Errors during embedding extraction also return `nil` so
    /// a transient inference failure degrades to "unknown speaker" rather
    /// than blocking the caption.
    func match(audio: [Float]) async -> String? {
        do {
            try await prepare()
        } catch {
            logger.warning("model load failed, falling back to channel default: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let models = loadedModels else { return nil }

        // Single-speaker mask is pre-allocated on the loaded models; the
        // extractor pads / loops the audio internally to its expected
        // 160 000-sample window, so short utterances are stretched rather
        // than truncated — same behaviour the batch path tolerates.
        let embedding: [Float]
        do {
            let embs = try models.extractor.getEmbeddings(audio: audio, masks: models.allOnesMask)
            guard let first = embs.first, !first.allSatisfy({ $0 == 0 }) else {
                // Extractor returns a zero vector for inactive speakers (mask
                // activity below threshold). Shouldn't happen for an all-ones
                // mask on real speech, but degrade gracefully if it does.
                return nil
            }
            embedding = first
        } catch {
            logger.warning("embedding extraction failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // `SpeakerMatcher` returns the input label verbatim when no
        // candidate clears threshold + margin (label-as-fallback). A fixed
        // sentinel string would collide if a user enrolled a speaker with
        // the same name. Per-call UUID guarantees no collision with any
        // user-chosen name in `speakers.json`.
        let sentinel = UUID().uuidString
        let result = speakerMatcher.match(embeddings: [sentinel: embedding])
        guard let name = result[sentinel], name != sentinel else { return nil }
        return name
    }

    private static func loadModels() async throws -> LoadedModels {
        let models = try await DiarizerModels.load()
        guard
            let segShape = models.segmentationModel.modelDescription
            .outputDescriptionsByName["segments"]?.multiArrayConstraint?.shape,
            segShape.count >= 2
        else {
            throw LiveSpeakerMatcherError.modelShapeUnavailable
        }
        let frameCount = segShape[1].intValue
        let extractor = EmbeddingExtractor(embeddingModel: models.embeddingModel)
        let mask: [[Float]] = [[Float](repeating: 1.0, count: frameCount)]
        logger.info("WeSpeaker (wespeaker_v2) loaded for live matching, frameCount=\(frameCount, privacy: .public)")
        return LoadedModels(
            extractor: extractor,
            weSpeakerFrameCount: frameCount,
            allOnesMask: mask,
        )
    }
}

enum LiveSpeakerMatcherError: Error {
    case modelShapeUnavailable
}
