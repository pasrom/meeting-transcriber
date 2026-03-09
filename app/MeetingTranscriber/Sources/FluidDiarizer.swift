import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer")

/// CoreML-based speaker diarization using FluidAudio (on-device, no HuggingFace token needed).
class FluidDiarizer: DiarizationProvider {
    private var manager: OfflineDiarizerManager?
    private var currentNumSpeakers: Int?

    var isAvailable: Bool { true }

    /// Normalize FluidAudio's "Speaker 0" format to "SPEAKER_0".
    private static func normalizeSpeakerId(_ id: String) -> String {
        id.replacingOccurrences(of: "Speaker ", with: "SPEAKER_")
    }

    func run(audioPath: URL, numSpeakers: Int?, meetingTitle: String) async throws -> MeetingTranscriber.DiarizationResult {
        // Recreate manager if numSpeakers changed
        if manager == nil || numSpeakers != currentNumSpeakers {
            var config = OfflineDiarizerConfig()
            if let n = numSpeakers, n > 0 {
                config = config.withSpeakers(exactly: n)
            }
            manager = OfflineDiarizerManager(config: config)
            try await manager!.prepareModels()
            currentNumSpeakers = numSpeakers
            logger.info("FluidAudio models ready")
        }

        logger.info("Starting diarization: \(audioPath.lastPathComponent)")
        let fluidResult = try await manager!.process(audioPath)

        let segments = fluidResult.segments.map { seg in
            MeetingTranscriber.DiarizationResult.Segment(
                start: TimeInterval(seg.startTimeSeconds),
                end: TimeInterval(seg.endTimeSeconds),
                speaker: Self.normalizeSpeakerId(seg.speakerId)
            )
        }

        var speakingTimes: [String: TimeInterval] = [:]
        for seg in segments {
            speakingTimes[seg.speaker, default: 0] += seg.end - seg.start
        }

        var embeddings: [String: [Float]]?
        if let db = fluidResult.speakerDatabase {
            embeddings = [:]
            for (id, emb) in db {
                embeddings![Self.normalizeSpeakerId(id)] = emb
            }
        }

        logger.info("Diarization complete: \(segments.count) segments, \(speakingTimes.count) speakers")

        return MeetingTranscriber.DiarizationResult(
            segments: segments,
            speakingTimes: speakingTimes,
            autoNames: [:],
            embeddings: embeddings
        )
    }
}
