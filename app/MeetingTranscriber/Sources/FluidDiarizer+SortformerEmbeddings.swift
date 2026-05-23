import FluidAudio
import Foundation
import os.log

private let embeddingLogger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer+Embeddings")

extension FluidDiarizer {
    /// Extract one 256-d centroid per active Sortformer speaker via the
    /// pyannote `wespeaker_v2` CoreML model, using **overlap-excluded
    /// masks** so frames with simultaneous speakers don't contaminate
    /// the centroid (DiariZen-style hybrid pipeline).
    ///
    /// Chunks the audio into 10-second windows matching WeSpeaker's input
    /// shape, picks the top-3 active speakers per chunk (WeSpeaker accepts
    /// `[3, frames]` masks), aggregates embeddings by running L2-normalised
    /// mean across chunks. Speakers below `EmbeddingExtractor`'s activity
    /// threshold get zero embeddings from the extractor and are filtered
    /// out of the per-speaker accumulator.
    ///
    /// This file is `.codecov.yml`-ignored: it is exercised end-to-end by
    /// `SortformerEmbeddingsE2ETests` under the `RUN_QUALITY_TESTS=1` lane,
    /// not by default xctest (which would need a 150 MB CoreML download).
    /// The pure helpers — `buildOverlapExcludedMasks`, `resampleMask`,
    /// `aggregateCentroids` — stay in `FluidDiarizer.swift` and are
    /// covered by `FluidDiarizerSortformerTests`.
    func extractSortformerEmbeddings(
        audioPath: URL,
        timeline: DiarizerTimeline,
    ) async throws -> [String: [Float]] {
        if sortformerEmbeddingModels == nil {
            sortformerEmbeddingModels = try await DiarizerModels.load()
            embeddingLogger.info("WeSpeaker (wespeaker_v2) loaded for Sortformer post-hoc embeddings")
        }
        // swiftlint:disable:next force_unwrapping
        let models = sortformerEmbeddingModels!
        let extractor = EmbeddingExtractor(embeddingModel: models.embeddingModel)

        // WeSpeaker expects masks shaped [3, weSpeakerFrameCount] where the
        // frame count is fixed by the companion pyannote segmentation model.
        // Query at runtime so a future model swap doesn't silently mis-shape.
        // Mirrors the pattern in `DiarizerManager.extractSpeakerEmbedding`.
        guard
            let segShape = models.segmentationModel.modelDescription
            .outputDescriptionsByName["segments"]?.multiArrayConstraint?.shape,
            segShape.count >= 2
        else {
            throw DiarizationError.notAvailable
        }
        let weSpeakerFrameCount = segShape[1].intValue

        let converter = AudioConverter(sampleRate: 16000.0)
        let audio = try converter.resampleAudioFile(audioPath)

        // Per-speaker masks at Sortformer's native frame rate (12.5 Hz),
        // with frames where ≥2 speakers exceed onset zeroed across all
        // speakers (overlap exclusion).
        let masks = Self.buildOverlapExcludedMasks(
            predictions: timeline.finalizedPredictions,
            numSpeakers: timeline.config.numSpeakers,
            threshold: timeline.config.onsetThreshold,
        )
        let maskFrameCount = masks.first?.count ?? 0
        guard maskFrameCount > 0 else { return [:] }

        let (sums, counts) = try accumulateChunkEmbeddings(
            audio: audio,
            masks: masks,
            frameDuration: Double(timeline.config.frameDurationSeconds),
            weSpeakerFrameCount: weSpeakerFrameCount,
            extractor: extractor,
        )

        let result = Self.aggregateCentroids(sums: sums, counts: counts)
        embeddingLogger.info(
            "Sortformer post-hoc embeddings: \(result.count) speakers from \(counts.values.reduce(0, +)) chunks",
        )
        return result
    }

    /// Walk the audio in 10s chunks, run WeSpeaker on the top-3 active
    /// speakers per chunk (the model's mask shape only fits 3), accumulate
    /// running sums + counts per global Sortformer speaker slot. Sortformer's
    /// 4th speaker (when present) gets covered in chunks where they rank in
    /// the top-3 of that window.
    private func accumulateChunkEmbeddings(
        audio: [Float],
        masks: [[Float]],
        frameDuration: Double,
        weSpeakerFrameCount: Int,
        extractor: EmbeddingExtractor,
    ) throws -> (sums: [String: [Float]], counts: [String: Int]) {
        let chunkSamples = 160_000 // 10s @ 16 kHz — matches EmbeddingExtractor's waveform shape
        let framesPerChunk = max(1, Int(10.0 / frameDuration))
        let numSpeakers = masks.count
        let maskFrameCount = masks.first?.count ?? 0

        var sums = [String: [Float]](minimumCapacity: numSpeakers)
        var counts = [String: Int](minimumCapacity: numSpeakers)

        var sampleStart = 0
        var frameStart = 0
        while sampleStart < audio.count, frameStart < maskFrameCount {
            let sampleEnd = min(sampleStart + chunkSamples, audio.count)
            let frameEnd = min(frameStart + framesPerChunk, maskFrameCount)
            let chunk = Array(audio[sampleStart ..< sampleEnd])
            let chunkMasks: [[Float]] = (0 ..< numSpeakers).map { Array(masks[$0][frameStart ..< frameEnd]) }
            let activity = (0 ..< numSpeakers).map { (slot: $0, sum: chunkMasks[$0].reduce(0, +)) }
            let topSlots = activity.sorted { $0.sum > $1.sum }.prefix(3).map(\.slot)
            let masksForCall = topSlots.map { Self.resampleMask(chunkMasks[$0], to: weSpeakerFrameCount) }

            let embs = try extractor.getEmbeddings(audio: chunk, masks: masksForCall)
            for (i, slot) in topSlots.enumerated() {
                let emb = embs[i]
                guard !emb.allSatisfy({ $0 == 0 }) else { continue }
                let label = "SPEAKER_\(slot)"
                sums[label] = sums[label].map { zip($0, emb).map(+) } ?? emb
                counts[label, default: 0] += 1
            }
            sampleStart = sampleEnd
            frameStart = frameEnd
        }
        return (sums, counts)
    }
}
