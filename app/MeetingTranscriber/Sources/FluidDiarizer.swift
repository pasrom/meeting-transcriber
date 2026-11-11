import CoreML
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
/// `@unchecked Sendable` because `DiarizationProvider` is `Sendable`: one
/// instance diarizes both tracks of a dual-source job, which
/// `PipelineQueue.runDualTrackDiarization` runs one after the other, not in
/// parallel. The lazily set `offlineProcessor` / `sortformerDiarizer` state is
/// not synchronised and relies on that order. Nemotron 3 mode does not: its
/// stream state is not thread-safe, so its runs go through `nemotronRunGate`.
final class FluidDiarizer: DiarizationProvider, @unchecked Sendable {
    let mode: DiarizerMode
    private var offlineProcessor: any OfflineDiarizationProcessing

    private var sortformerDiarizer: SortformerDiarizer?
    /// Builds a ready Sortformer diarizer for the requested compute units and
    /// reports the units its loaded model carries. Everything that needs the
    /// real model sits behind this one seam, so a test can supply a stub.
    private let makeSortformerDiarizer: (MLComputeUnits) async throws -> (SortformerDiarizer, MLComputeUnits)
    /// Lazily-loaded Nemotron 3 diarizer, used only by
    /// `FluidDiarizer+Nemotron.runNemotron`. Not `private` because that
    /// extension lives in a separate file. Unlike the CoreML inference it
    /// carries streaming state and is not thread-safe, so it is only touched
    /// inside `nemotronRunGate`; `runNemotron` resets it at the start of a run.
    var nemotronDiarizer: (any NemotronStreamingDiarizing)?
    /// Serialises Nemotron 3 runs on this instance, so in this mode, unlike
    /// Offline and Sortformer, `run` is safe to call concurrently.
    let nemotronRunGate = AsyncSerialGate()
    /// Loads the Nemotron 3 model for the requested compute units and returns
    /// a ready streaming diarizer plus the units its loaded model carries.
    /// Everything that needs the real model sits behind this one seam, so a
    /// test can supply a stub. Not `private` for the same reason as
    /// `nemotronDiarizer`.
    let makeNemotronDiarizer: (MLComputeUnits) async throws -> (any NemotronStreamingDiarizing, MLComputeUnits)
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
        makeSortformerDiarizer: @escaping (MLComputeUnits) async throws -> (SortformerDiarizer, MLComputeUnits) = { computeUnits in
            let diarizer = SortformerDiarizer()
            let models = try await SortformerModels.loadFromHuggingFace(config: .default, computeUnits: computeUnits)
            diarizer.initialize(models: models)
            return (diarizer, models.mainModel.configuration.computeUnits)
        },
        makeNemotronDiarizer: @escaping (MLComputeUnits) async throws -> (any NemotronStreamingDiarizing, MLComputeUnits) = { computeUnits in
            try await FluidDiarizer.loadNemotronDiarizer(computeUnits: computeUnits)
        },
    ) {
        self.mode = mode
        self.offlineProcessor = offlineProcessor ?? FluidOfflineProcessor(tuning: tuning)
        self.makeSortformerDiarizer = makeSortformerDiarizer
        self.makeNemotronDiarizer = makeNemotronDiarizer
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

        case .nemotron:
            try await runNemotron(audioPath: audioPath, numSpeakers: numSpeakers)
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

    /// Compute units for the Sortformer model. Left to FluidAudio (nil), the
    /// default config resolves to `.all`, and Core ML's plan then puts more
    /// than a third of the graph's operations on the GPU. With CPU + Neural
    /// Engine those move to the Neural Engine. Measured on an M3 Max with the
    /// three quality fixtures: the Sortformer pass ran 21 to 24 % faster, DER
    /// was identical on two fixtures and 0.0009 higher on the third. The first
    /// run after a model or OS update pays a one-time compile for the new
    /// routing. FluidAudio forwards an explicit value to Core ML unchanged;
    /// only `nil` goes through its own `recommendedComputeUnits` choice.
    /// This is a speed choice, not a crash fix: the WeSpeaker embeddings that
    /// follow in Sortformer mode keep FluidAudio's default routing.
    static let sortformerComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    /// Log label for compute units read back from a loaded model.
    static func computeUnitsLabel(_ units: MLComputeUnits) -> String {
        units == .cpuAndNeuralEngine ? "cpuAndNeuralEngine" : "rawValue \(units.rawValue)"
    }

    private func runSortformer(audioPath: URL) async throws -> MeetingTranscriber.DiarizationResult {
        if sortformerDiarizer == nil {
            let (diarizer, routed) = try await makeSortformerDiarizer(Self.sortformerComputeUnits)
            sortformerDiarizer = diarizer
            // `routed` is read back from the loaded model, so the log shows the
            // routing Core ML was given rather than the value this file asked for.
            logger.info("FluidAudio Sortformer models ready (computeUnits: \(Self.computeUnitsLabel(routed), privacy: .public))")
        }

        logger.info("Starting Sortformer diarization: \(audioPath.lastPathComponent)")
        // swiftlint:disable:next force_unwrapping
        let timeline = try sortformerDiarizer!.processComplete(audioFileURL: audioPath)

        // Phase 1 of issue #165: run WeSpeaker post-hoc on Sortformer's
        // overlap-excluded frames so the naming dialog + SpeakerMatcher
        // light up again. Without this, Sortformer mode produces
        // `embeddings: nil` and `PipelineQueue.processNext()` aborts the
        // naming flow (issue #109).
        let embeddings = try await extractSortformerEmbeddings(audioPath: audioPath, timeline: timeline)

        return Self.buildResult(segments: Self.segments(from: timeline), speakerDatabase: embeddings)
    }

    /// One segment per finalized timeline segment, labelled by speaker slot
    /// (`SPEAKER_<slot>`, the same key the post-hoc embeddings use). Shared by
    /// the Sortformer and Nemotron 3 modes, which both end in a
    /// `DiarizerTimeline`. Pure so unit tests can pin it without a model.
    static func segments(from timeline: DiarizerTimeline) -> [MeetingTranscriber.DiarizationResult.Segment] {
        timeline.speakers.flatMap { index, speaker in
            let label = normalizeSpeakerId(speaker.name ?? "Speaker \(index)")
            return speaker.finalizedSegments.map { seg in
                MeetingTranscriber.DiarizationResult.Segment(
                    start: TimeInterval(seg.startTime),
                    end: TimeInterval(seg.endTime),
                    speaker: label,
                )
            }
        }
    }

    // MARK: - Nemotron 3 Mode (Nemotron3Diarizer)

    /// Nemotron 3 preset: `fast128` feeds the model 10.24 s of audio per call.
    /// FluidAudio's benchmark (AMI test, 16 meetings) has it at the lowest
    /// error of the published presets, with the speaker count right in all 16
    /// meetings; the window length is what buys the counting, and counting
    /// more than four speakers is the reason to pick this mode at all. Its
    /// 10.56 s latency does not matter after the meeting. `offline` (30 s
    /// window) is faster but does not compile for the Neural Engine and got
    /// the count wrong in two meetings; the 95 MB `c128-split-w8a8` build
    /// would halve the download for a slightly higher error.
    static let nemotronConfig = Nemotron3Config.fast128

    /// Compute units for the Nemotron 3 model. `Nemotron3Models.loadFromHuggingFace`
    /// defaults to `.all`, which lets Core ML put parts of the graph on the
    /// GPU; this keeps it off that path like the other two modes (see
    /// `FluidOfflineProcessor.makeModelConfiguration` and
    /// `sortformerComputeUnits`). The `fast128` preset compiles for the
    /// Neural Engine. Unlike Sortformer's, this choice has not been
    /// benchmarked against `.all`.
    static let nemotronComputeUnits: MLComputeUnits = .cpuAndNeuralEngine

    /// Turns Nemotron 3's frame probabilities into segments: its 10 ms frames,
    /// the 0.5 activity threshold Sortformer mode uses, and speech shorter
    /// than 0.2 s dropped, the default of FluidAudio's own
    /// `Nemotron3Diarizer.segments`. Without that floor a 10 ms frame grid
    /// turns every flicker around the threshold into a segment of its own.
    static let nemotronTimelineConfig = DiarizerTimelineConfig(
        numSpeakers: nemotronConfig.numSpeakers,
        frameDurationSeconds: nemotronConfig.outputFrameSeconds,
        onsetPadSeconds: 0,
        offsetPadSeconds: 0,
        minDurationOn: 0.2,
        minDurationOff: 0,
    )

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

    /// WeSpeaker's waveform input: 10 s at 16 kHz, the shape
    /// `EmbeddingExtractor.getEmbeddings` feeds the model.
    static let weSpeakerWindowSamples = 160_000

    /// Hop between post-hoc embedding chunks. Non-overlapping windows today,
    /// so equal to the model window, but a separate choice from it.
    static let embeddingChunkStrideSamples = weSpeakerWindowSamples

    /// Minimum active WeSpeaker frames (about 0.17 s) for a slot to be
    /// embedded in a chunk: `EmbeddingExtractor.getEmbeddings`' default
    /// `minActivityThreshold`, so full chunks are gated exactly as the
    /// extractor gates them.
    static let minActiveWeSpeakerFrames: Float = 10

    /// One WeSpeaker call of the post-hoc embedding walk: which audio it
    /// covers, which global speaker slots it embeds, and their masks on
    /// WeSpeaker's frame grid over the full 10 s window.
    struct EmbeddingChunkPlan: Equatable {
        let sampleRange: Range<Int>
        let slots: [Int]
        let masks: [[Float]]
    }

    /// Plan the post-hoc embedding walk: 10 s chunks, top-3 active speaker
    /// slots per chunk (WeSpeaker's mask shape only fits 3), each slot's
    /// mask mapped by `weSpeakerWindowMask`. Pure so the geometry is pinned
    /// without loading a model.
    ///
    /// A slot is embedded only with at least `minActiveWeSpeakerFrames`
    /// active frames inside the chunk's own audio; counting the loop-padded
    /// copies would lower the bar for a short tail by the repeat factor. A
    /// chunk with no such slot is skipped without a model call; that covers
    /// a tail too short for one frame, which could otherwise run the model
    /// on an empty mask.
    static func planEmbeddingChunks(
        audioSampleCount: Int,
        masks: [[Float]],
        samplesPerMaskFrame: Int,
        weSpeakerFrameCount: Int,
    ) -> [EmbeddingChunkPlan] {
        let maskFrameCount = masks.first?.count ?? 0
        guard samplesPerMaskFrame > 0, maskFrameCount > 0, weSpeakerFrameCount > 0 else { return [] }
        var plans: [EmbeddingChunkPlan] = []
        for sampleStart in stride(from: 0, to: audioSampleCount, by: embeddingChunkStrideSamples) {
            let sampleEnd = min(sampleStart + weSpeakerWindowSamples, audioSampleCount)
            let chunkSampleCount = sampleEnd - sampleStart
            let frameStart = sampleStart / samplesPerMaskFrame
            // Past the mask's end there is nothing to embed (and nothing to slice).
            guard frameStart < maskFrameCount else { break }
            let frameEnd = min(
                frameStart + (chunkSampleCount + samplesPerMaskFrame - 1) / samplesPerMaskFrame,
                maskFrameCount,
            )
            // WeSpeaker frames starting inside the chunk's audio; the rest
            // of the window is loop padding.
            let framesInAudio = (chunkSampleCount * weSpeakerFrameCount + weSpeakerWindowSamples - 1)
                / weSpeakerWindowSamples
            let chunkMasks: [[Float]] = masks.map { Array($0[frameStart ..< frameEnd]) }
            let activity: [(slot: Int, sum: Float)] = chunkMasks.indices.map { ($0, chunkMasks[$0].reduce(0, +)) }
            var slots: [Int] = []
            var windowMasks: [[Float]] = []
            for candidate in activity.sorted(by: { $0.sum > $1.sum }).prefix(3) {
                let windowMask = weSpeakerWindowMask(
                    chunkMasks[candidate.slot],
                    samplesPerMaskFrame: samplesPerMaskFrame,
                    chunkSampleCount: chunkSampleCount,
                    frameCount: weSpeakerFrameCount,
                )
                let activeInAudio: Float = windowMask[0 ..< framesInAudio].reduce(0, +)
                guard activeInAudio >= minActiveWeSpeakerFrames else { continue }
                slots.append(candidate.slot)
                windowMasks.append(windowMask)
            }
            guard !slots.isEmpty else { continue }
            plans.append(EmbeddingChunkPlan(sampleRange: sampleStart ..< sampleEnd, slots: slots, masks: windowMasks))
        }
        return plans
    }

    /// Map one chunk's diarizer-rate mask onto WeSpeaker's `frameCount`
    /// frames spanning the full 10 s window, in phase with
    /// `weSpeakerWindow`'s loop-padded audio: each WeSpeaker frame takes the
    /// diarizer frame under the audio sample it starts on, after the loop.
    /// Zero where that frame is missing (the diarizer's frame count need not
    /// match the audio length exactly).
    ///
    /// Stretching a short chunk's mask over the whole window instead put the
    /// activity of the chunk's first fraction under all of its audio, since
    /// the extractor reads only the frames its unpadded audio fills.
    static func weSpeakerWindowMask(
        _ mask: [Float],
        samplesPerMaskFrame: Int,
        chunkSampleCount: Int,
        frameCount: Int,
    ) -> [Float] {
        guard samplesPerMaskFrame > 0, chunkSampleCount > 0, frameCount > 0 else { return [] }
        return (0 ..< frameCount).map { frame in
            let sample = (frame * weSpeakerWindowSamples / frameCount) % chunkSampleCount
            let src = sample / samplesPerMaskFrame
            return src < mask.count ? mask[src] : 0
        }
    }

    /// The chunk's audio, loop-padded to the full WeSpeaker window, as
    /// `EmbeddingExtractor` itself pads short audio. Padding here instead
    /// keeps the mask in phase sample by sample (`weSpeakerWindowMask`)
    /// and lets the extractor read every frame. Zero padding measurably
    /// degrades short-tail embeddings: a window that is mostly digital
    /// silence pulled tail embeddings far from the same speaker's full
    /// chunks on every fixture tried.
    static func weSpeakerWindow(_ audio: [Float], range: Range<Int>) -> [Float] {
        guard !range.isEmpty else { return [Float](repeating: 0, count: weSpeakerWindowSamples) }
        return (0 ..< weSpeakerWindowSamples).map { audio[range.lowerBound + $0 % range.count] }
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
    private let prepareModels: (OfflineDiarizerManager, MLModelConfiguration) async throws -> Void

    init(
        tuning: OfflineDiarizerTuning = .defaults,
        prepareModels: @escaping (OfflineDiarizerManager, MLModelConfiguration) async throws -> Void = { manager, configuration in
            try await manager.prepareModels(configuration: configuration)
        },
    ) {
        self.tuning = tuning
        self.prepareModels = prepareModels
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

    /// Keep FluidAudio's offline inference off Metal. Core ML's `.all`
    /// routing can send the WeSpeaker embedding model through MPSGraph, whose
    /// in-process abort cannot be caught or retried by the pipeline. The CPU +
    /// Neural Engine route retains hardware acceleration without invoking the
    /// crash-prone GPU path. FluidAudio 0.15.5+ reads only `computeUnits` from
    /// this configuration; older releases silently use `.all` instead.
    /// `LiveSpeakerMatcher` loads the same embedding model and reads
    /// `computeUnits` too, so the two paths cannot drift apart.
    static let computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    static func makeModelConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return configuration
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
        try await prepareModels(newManager, Self.makeModelConfiguration())
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
