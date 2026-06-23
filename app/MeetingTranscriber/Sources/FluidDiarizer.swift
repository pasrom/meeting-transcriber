import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer")

protocol OfflineDiarizationProcessing {
    mutating func prepare(numSpeakers: Int?) async throws
    func process(audioPath: URL) async throws -> DiarizationResult
}

/// User-tunable subset of `OfflineDiarizerConfig` exposed via Settings.
/// Decouples `FluidOfflineProcessor` from `AppSettings`/UserDefaults so the
/// plumbing stays unit-testable.
struct OfflineDiarizerTuning: Equatable {
    var clusterThreshold: Double
    var warmStartFa: Double
    var warmStartFb: Double
    var minSegmentDurationSeconds: Double
    var excludeOverlap: Bool

    /// Defaults matching FluidAudio's `Clustering.community` and `Embedding.community`.
    static let defaults = Self(
        clusterThreshold: 0.6,
        warmStartFa: 0.07,
        warmStartFb: 0.8,
        minSegmentDurationSeconds: 1.0,
        excludeOverlap: true,
    )

    /// Apply this tuning to an `OfflineDiarizerConfig`, preserving everything else
    /// (segmentation, vbx, postProcessing, export, speaker count constraints).
    func apply(to config: OfflineDiarizerConfig) -> OfflineDiarizerConfig {
        var copy = config
        copy.clustering.threshold = clusterThreshold
        copy.clustering.warmStartFa = warmStartFa
        copy.clustering.warmStartFb = warmStartFb
        copy.embedding.minSegmentDurationSeconds = minSegmentDurationSeconds
        copy.embedding.excludeOverlap = excludeOverlap
        return copy
    }
}

/// CoreML-based speaker diarization using FluidAudio (on-device, no HuggingFace token needed).
/// `@unchecked Sendable` because `PipelineQueue` shares one instance across
/// two `async let` diarisation runs. The mutable `offlineProcessor` /
/// `sortformerDiarizer` are init-once-then-read; the underlying FluidAudio
/// CoreML inference is documented thread-safe.
final class FluidDiarizer: DiarizationProvider, @unchecked Sendable {
    let mode: DiarizerMode
    private var offlineProcessor: any OfflineDiarizationProcessing

    private var sortformerDiarizer: SortformerDiarizer?
    /// Lazily-loaded WeSpeaker (pyannote `wespeaker_v2`) models, used only by
    /// `FluidDiarizer+SortformerEmbeddings.extractSortformerEmbeddings`. Not
    /// `private` because the extension lives in a separate file (codecov-
    /// ignored — see `.codecov.yml`).
    var sortformerEmbeddingModels: DiarizerModels?

    var isAvailable: Bool {
        true
    }

    init(
        mode: DiarizerMode = .offline,
        tuning: OfflineDiarizerTuning = .defaults,
        offlineProcessor: (any OfflineDiarizationProcessing)? = nil,
    ) {
        self.mode = mode
        self.offlineProcessor = offlineProcessor ?? FluidOfflineProcessor(tuning: tuning)
    }

    /// Normalize FluidAudio's "Speaker 0" format to "SPEAKER_0".
    static func normalizeSpeakerId(_ id: String) -> String {
        id.replacingOccurrences(of: "Speaker ", with: "SPEAKER_")
    }

    func run(
        audioPath: URL,
        numSpeakers: Int?,
        meetingTitle _: String,
    ) async throws -> MeetingTranscriber.DiarizationResult {
        switch mode {
        case .offline:
            try await runOffline(audioPath: audioPath, numSpeakers: numSpeakers)

        case .sortformer:
            try await runSortformer(audioPath: audioPath)
        }
    }

    // MARK: - Offline Mode

    private func runOffline(
        audioPath: URL,
        numSpeakers: Int?,
    ) async throws -> MeetingTranscriber.DiarizationResult {
        try await offlineProcessor.prepare(numSpeakers: numSpeakers)

        logger.info("Starting offline diarization: \(audioPath.lastPathComponent)")

        do {
            return try await offlineProcessor.process(audioPath: audioPath)
        } catch {
            // If numSpeakers was specified, retry with auto-detect as fallback
            guard let numSpeakers, numSpeakers > 0 else {
                throw error
            }

            logger.warning(
                "Diarization failed with numSpeakers=\(numSpeakers), retrying with auto-detect: \(error.localizedDescription, privacy: .public)",
            )

            try await offlineProcessor.prepare(numSpeakers: nil)
            return try await offlineProcessor.process(audioPath: audioPath)
        }
    }

    // MARK: - Sortformer Mode (SortformerDiarizer)

    private func runSortformer(audioPath: URL) async throws -> MeetingTranscriber.DiarizationResult {
        if sortformerDiarizer == nil {
            let diarizer = SortformerDiarizer()
            let models = try await SortformerModels.loadFromHuggingFace(config: .default)
            diarizer.initialize(models: models)
            sortformerDiarizer = diarizer
            logger.info("FluidAudio Sortformer models ready")
        }

        logger.info("Starting Sortformer diarization: \(audioPath.lastPathComponent)")
        // swiftlint:disable:next force_unwrapping
        let timeline = try sortformerDiarizer!.processComplete(audioFileURL: audioPath)

        let segments = timeline.speakers.flatMap { index, speaker in
            let label = Self.normalizeSpeakerId(speaker.name ?? "Speaker \(index)")
            return speaker.finalizedSegments.map { seg in
                MeetingTranscriber.DiarizationResult.Segment(
                    start: TimeInterval(seg.startTime),
                    end: TimeInterval(seg.endTime),
                    speaker: label,
                )
            }
        }

        // Phase 1 of issue #165: run WeSpeaker post-hoc on Sortformer's
        // overlap-excluded frames so the naming dialog + SpeakerMatcher
        // light up again. Without this, Sortformer mode produces
        // `embeddings: nil` and `PipelineQueue.processNext()` aborts the
        // naming flow (issue #109).
        let embeddings = try await extractSortformerEmbeddings(audioPath: audioPath, timeline: timeline)

        return Self.buildResult(segments: segments, speakerDatabase: embeddings)
    }

    /// L2-normalised running-mean of per-chunk embeddings → one centroid
    /// per speaker. Pure so unit tests can pin behaviour without CoreML.
    static func aggregateCentroids(
        sums: [String: [Float]],
        counts: [String: Int],
    ) -> [String: [Float]] {
        var result = [String: [Float]](minimumCapacity: sums.count)
        for (label, sum) in sums {
            let count = Float(counts[label] ?? 1)
            var mean = sum.map { $0 / count }
            let norm = (mean.reduce(into: Float(0)) { $0 += $1 * $1 }).squareRoot()
            if norm > 1e-9 {
                mean = mean.map { $0 / norm }
            }
            result[label] = mean
        }
        return result
    }

    /// Nearest-neighbour resample a per-frame activity mask onto a target
    /// frame grid. Used to bridge Sortformer's 12.5 Hz output (~125 frames/10s)
    /// to WeSpeaker's expected segmentation-frame count (typically 589/10s).
    /// Pure so the unit tests can pin it without loading any model.
    static func resampleMask(_ mask: [Float], to targetCount: Int) -> [Float] {
        guard !mask.isEmpty, targetCount > 0 else {
            return Array(repeating: Float(0.0), count: max(0, targetCount))
        }
        var out = Array(repeating: Float(0.0), count: targetCount)
        let srcCount = mask.count
        for i in 0 ..< targetCount {
            let srcIdx = min(i * srcCount / targetCount, srcCount - 1)
            out[i] = mask[srcIdx]
        }
        return out
    }

    /// Pure helper exposed for testability — build per-speaker activity
    /// masks (1.0/0.0) with overlap-exclusion: any frame where ≥2 speakers
    /// exceed `threshold` is zeroed across ALL speakers, so impure frames
    /// never reach embedding extraction. DiariZen's stage-5 design.
    ///
    /// - Parameters:
    ///   - predictions: flat `[numFrames × numSpeakers]` from `DiarizerTimeline.finalizedPredictions`.
    ///   - numSpeakers: speaker-slot count (Sortformer hardcodes 4).
    ///   - threshold: activity threshold (use `timeline.config.onsetThreshold`, 0.5 default).
    /// - Returns: `[numSpeakers]` arrays of length `numFrames`.
    static func buildOverlapExcludedMasks(
        predictions: [Float],
        numSpeakers: Int,
        threshold: Float,
    ) -> [[Float]] {
        guard numSpeakers > 0, !predictions.isEmpty else { return [] }
        let numFrames = predictions.count / numSpeakers
        guard numFrames > 0 else { return [] }
        var masks = Array(repeating: Array(repeating: Float(0.0), count: numFrames), count: numSpeakers)

        for frame in 0 ..< numFrames {
            let base = frame * numSpeakers
            var activeSlot = -1
            var activeCount = 0
            for s in 0 ..< numSpeakers where predictions[base + s] >= threshold {
                activeCount += 1
                activeSlot = s
                if activeCount > 1 { break }
            }
            if activeCount == 1 {
                masks[activeSlot][frame] = 1.0
            }
        }
        return masks
    }

    // MARK: - Shared Result Conversion

    static func buildResult(
        segments unsorted: [MeetingTranscriber.DiarizationResult.Segment],
        speakerDatabase: [String: [Float]]?, // swiftlint:disable:this discouraged_optional_collection
    ) -> MeetingTranscriber.DiarizationResult {
        let segments = unsorted.sorted { $0.start < $1.start }

        var speakingTimes: [String: TimeInterval] = [:]
        for seg in segments {
            speakingTimes[seg.speaker, default: 0] += seg.end - seg.start
        }

        var embeddings: [String: [Float]]? // swiftlint:disable:this discouraged_optional_collection
        if let db = speakerDatabase {
            embeddings = [:]
            for (id, emb) in db {
                embeddings?[Self.normalizeSpeakerId(id)] = emb
            }
        }

        logger.info("Diarization complete: \(segments.count) segments, \(speakingTimes.count) speakers")

        return MeetingTranscriber.DiarizationResult(
            segments: segments,
            speakingTimes: speakingTimes,
            autoNames: [:],
            embeddings: embeddings,
        )
    }
}

// MARK: - FluidAudio Offline Processor (production implementation)

struct FluidOfflineProcessor: OfflineDiarizationProcessing {
    private var manager: OfflineDiarizerManager?
    private var currentNumSpeakers: Int?
    private let tuning: OfflineDiarizerTuning

    init(tuning: OfflineDiarizerTuning = .defaults) {
        self.tuning = tuning
    }

    /// Build the `OfflineDiarizerConfig` from a tuning struct + optional speaker count.
    /// Pure helper so unit tests can verify the produced config without standing up
    /// the actual CoreML manager.
    static func makeConfig(tuning: OfflineDiarizerTuning, numSpeakers: Int?) -> OfflineDiarizerConfig {
        var config = tuning.apply(to: OfflineDiarizerConfig())
        if let n = numSpeakers, n > 0 {
            // Force EXACTLY n, not merely cap at n. FluidAudio only re-clusters
            // when the natural detection falls outside the speaker bounds, so a
            // cap-only constraint left an under-detected count untouched — the
            // "Expected Speakers" setting and the naming dialog's "Wrong count?"
            // re-run were silent no-ops whenever the detector found ≤ n.
            config = config.withSpeakers(exactly: n)
        }
        return config
    }

    mutating func prepare(numSpeakers: Int?) async throws {
        guard manager == nil || numSpeakers != currentNumSpeakers else { return }

        // Explicitly deallocate previous manager to prevent resource conflicts
        manager = nil
        let t = tuning
        let config = Self.makeConfig(tuning: t, numSpeakers: numSpeakers)
        let flag = t == .defaults ? "defaults" : "modified"
        logger
            .info(
                "FluidAudio offline tuning (\(flag)): clusterThreshold=\(t.clusterThreshold) warmStartFa=\(t.warmStartFa) warmStartFb=\(t.warmStartFb) minSegmentDurationSeconds=\(t.minSegmentDurationSeconds) excludeOverlap=\(t.excludeOverlap)",
            )
        let newManager = OfflineDiarizerManager(config: config)
        try await newManager.prepareModels()
        manager = newManager
        currentNumSpeakers = numSpeakers
        logger.info("FluidAudio offline models ready")
    }

    func process(audioPath: URL) async throws -> DiarizationResult {
        guard let manager else {
            throw DiarizationError.notPrepared
        }
        let fluidResult = try await manager.process(audioPath)
        let segments = fluidResult.segments.map { seg in
            DiarizationResult.Segment(
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds),
                speaker: FluidDiarizer.normalizeSpeakerId(seg.speakerId),
            )
        }
        return FluidDiarizer.buildResult(segments: segments, speakerDatabase: fluidResult.speakerDatabase)
    }
}
