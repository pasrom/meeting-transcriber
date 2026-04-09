import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer")

protocol OfflineDiarizationProcessing {
    mutating func prepare(numSpeakers: Int?) async throws
    func process(audioPath: URL) async throws -> DiarizationResult
}

/// CoreML-based speaker diarization using FluidAudio (on-device, no HuggingFace token needed).
class FluidDiarizer: DiarizationProvider {
    let mode: DiarizerMode
    private var offlineProcessor: OfflineDiarizationProcessing

    private var sortformerDiarizer: SortformerDiarizer?

    var isAvailable: Bool {
        true
    }

    init(mode: DiarizerMode = .offline, offlineProcessor: OfflineDiarizationProcessing? = nil) {
        self.mode = mode
        self.offlineProcessor = offlineProcessor ?? FluidOfflineProcessor()
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
                "Diarization failed with numSpeakers=\(numSpeakers), retrying with auto-detect: \(error.localizedDescription)",
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

        return Self.buildResult(segments: segments, speakerDatabase: nil)
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

    mutating func prepare(numSpeakers: Int?) async throws {
        guard manager == nil || numSpeakers != currentNumSpeakers else { return }

        // Explicitly deallocate previous manager to prevent resource conflicts
        manager = nil
        var config = OfflineDiarizerConfig()
        if let n = numSpeakers, n > 0 {
            config = config.withSpeakers(min: 1, max: n)
        }
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
