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
    /// The pure helpers — `buildOverlapExcludedMasks`,
    /// `planEmbeddingChunks`, `aggregateCentroids` — stay in `FluidDiarizer.swift` and are
    /// covered by `FluidDiarizerSortformerTests`.
    func extractSortformerEmbeddings(
        audioPath: URL,
        timeline: DiarizerTimeline,
    ) async throws -> [String: [Float]] {
        let converter = AudioConverter(sampleRate: 16000.0)
        let audio = try converter.resampleAudioFile(audioPath)
        return try await extractSortformerEmbeddings(audio: audio, timeline: timeline)
    }

    /// Same, for audio already decoded to 16 kHz mono. Nemotron 3 mode uses
    /// this: its model is an 8-speaker streaming Sortformer, its timeline
    /// has the same shape at 10 ms instead of 80 ms frames (the chunk walk
    /// derives its frame counts from `timeline.config`), and it has the
    /// samples in hand already, so decoding the file a second time would
    /// only cost time.
    func extractSortformerEmbeddings(
        audio: [Float],
        timeline: DiarizerTimeline,
    ) async throws -> [String: [Float]] {
        if sortformerEmbeddingModels == nil {
            sortformerEmbeddingModels = try await loadEmbeddingModels(FluidOfflineProcessor.computeUnits)
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

        // Per-speaker masks at the diarizer's native frame rate (12.5 Hz
        // for Sortformer, 100 Hz for Nemotron 3), with frames where ≥2
        // speakers exceed onset zeroed across all speakers (overlap
        // exclusion).
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

    /// Run WeSpeaker on each planned chunk (see `planEmbeddingChunks`) and
    /// accumulate running sums + counts per global speaker slot. A speaker
    /// beyond the third (Sortformer's 4th, Nemotron 3's 4th to 8th) gets
    /// covered in chunks where they rank in the top-3 of that window.
    private func accumulateChunkEmbeddings(
        audio: [Float],
        masks: [[Float]],
        frameDuration: Double,
        weSpeakerFrameCount: Int,
        extractor: EmbeddingExtractor,
    ) throws -> (sums: [String: [Float]], counts: [String: Int]) {
        let plans = Self.planEmbeddingChunks(
            audioSampleCount: audio.count,
            masks: masks,
            // 1280 samples for Sortformer's 80 ms frames, 160 for Nemotron 3's 10 ms.
            samplesPerMaskFrame: Int((frameDuration * 16000).rounded()),
            weSpeakerFrameCount: weSpeakerFrameCount,
        )
        var sums = [String: [Float]](minimumCapacity: masks.count)
        var counts = [String: Int](minimumCapacity: masks.count)
        for plan in plans {
            let window = Self.weSpeakerWindow(audio, range: plan.sampleRange)
            let embs = try extractor.getEmbeddings(audio: window, masks: plan.masks)
            for (i, slot) in plan.slots.enumerated() {
                let emb = embs[i]
                guard !emb.allSatisfy({ $0 == 0 }) else { continue }
                let label = "SPEAKER_\(slot)"
                sums[label] = sums[label].map { zip($0, emb).map(+) } ?? emb
                counts[label, default: 0] += 1
            }
        }
        return (sums, counts)
    }
}
