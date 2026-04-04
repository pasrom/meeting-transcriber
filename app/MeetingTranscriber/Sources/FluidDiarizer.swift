import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer")

/// CoreML-based speaker diarization using FluidAudio (on-device, no HuggingFace token needed).
class FluidDiarizer: DiarizationProvider {
    let mode: DiarizerMode

    private var offlineManager: OfflineDiarizerManager?
    private var sortformerDiarizer: SortformerDiarizer?
    private var currentNumSpeakers: Int?

    var isAvailable: Bool {
        true
    }

    init(mode: DiarizerMode = .offline) {
        self.mode = mode
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

    // MARK: - Offline Mode (OfflineDiarizerManager)

    private func runOffline(
        audioPath: URL,
        numSpeakers: Int?,
    ) async throws -> MeetingTranscriber.DiarizationResult {
        // Recreate manager if numSpeakers changed
        if offlineManager == nil || numSpeakers != currentNumSpeakers {
            var config = OfflineDiarizerConfig()
            if let n = numSpeakers, n > 0 {
                config = config.withSpeakers(exactly: n)
            }
            let newManager = OfflineDiarizerManager(config: config)
            try await newManager.prepareModels()
            offlineManager = newManager
            currentNumSpeakers = numSpeakers
            logger.info("FluidAudio offline models ready")
        }

        logger.info("Starting offline diarization: \(audioPath.lastPathComponent)")
        // swiftlint:disable:next force_unwrapping
        let fluidResult = try await offlineManager!.process(audioPath)

        let segments = fluidResult.segments.map { seg in
            MeetingTranscriber.DiarizationResult.Segment(
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds),
                speaker: Self.normalizeSpeakerId(seg.speakerId),
            )
        }

        return buildResult(segments: segments, speakerDatabase: fluidResult.speakerDatabase)
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

        return buildResult(segments: segments, speakerDatabase: nil)
    }

    // MARK: - Shared Result Conversion

    func buildResult(
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
