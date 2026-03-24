import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidDiarizer")

/// LS-EEND speaker diarization with WeSpeaker embedding extraction (on-device, no HuggingFace token needed).
/// Stage 1: LSEENDDiarizer produces speaker segments (who spoke when).
/// Stage 2: DiarizerManager extracts per-speaker WeSpeaker embeddings for cross-meeting speaker matching.
class FluidDiarizer: DiarizationProvider {
    private var diarizer: LSEENDDiarizer?
    private var embeddingManager: DiarizerManager?

    /// WeSpeaker expects 16 kHz audio for embedding extraction.
    private static let embeddingSampleRate: Float = 16_000

    var isAvailable: Bool {
        true
    }

    /// Normalize FluidAudio's "Speaker 0" format to "SPEAKER_0".
    private static func normalizeSpeakerLabel(_ index: Int) -> String {
        "SPEAKER_\(index)"
    }

    func run(audioPath: URL, numSpeakers _: Int?, meetingTitle _: String) async throws -> MeetingTranscriber.DiarizationResult {
        // Stage 1: LS-EEND diarization
        if diarizer == nil {
            let d = LSEENDDiarizer()
            try await d.initialize(variant: .dihard3)
            diarizer = d
            logger.info("LS-EEND models ready")
        } else {
            diarizer?.reset()
        }

        logger.info("Starting diarization: \(audioPath.lastPathComponent)")
        // swiftlint:disable:next force_unwrapping
        let timeline = try diarizer!.processComplete(audioFileURL: audioPath)

        // Extract segments from all speakers in the timeline
        var segments: [MeetingTranscriber.DiarizationResult.Segment] = []
        for speaker in timeline.speakers.values {
            let speakerLabel = Self.normalizeSpeakerLabel(speaker.index)
            for seg in speaker.finalizedSegments {
                segments.append(MeetingTranscriber.DiarizationResult.Segment(
                    start: TimeInterval(seg.startTime),
                    end: TimeInterval(seg.endTime),
                    speaker: speakerLabel,
                ))
            }
        }
        segments.sort { $0.start < $1.start }

        var speakingTimes: [String: TimeInterval] = [:]
        for seg in segments {
            speakingTimes[seg.speaker, default: 0] += seg.end - seg.start
        }

        logger.info("Diarization complete: \(segments.count) segments, \(speakingTimes.count) speakers")

        // Stage 2: WeSpeaker embedding extraction per speaker
        let embeddings = await extractSpeakerEmbeddings(audioPath: audioPath, segments: segments)

        return MeetingTranscriber.DiarizationResult(
            segments: segments,
            speakingTimes: speakingTimes,
            autoNames: [:],
            embeddings: embeddings,
        )
    }

    /// Extract WeSpeaker embeddings for each unique speaker by slicing audio at segment boundaries.
    private func extractSpeakerEmbeddings(
        audioPath: URL,
        segments: [MeetingTranscriber.DiarizationResult.Segment],
    ) async -> [String: [Float]]? { // swiftlint:disable:this discouraged_optional_collection
        do {
            if embeddingManager == nil {
                let models = try await DiarizerModels.downloadIfNeeded()
                let manager = DiarizerManager()
                manager.initialize(models: models)
                embeddingManager = manager
                logger.info("WeSpeaker embedding model ready")
            }

            let converter = AudioConverter()
            let audioSamples = try converter.resampleAudioFile(audioPath)

            let uniqueSpeakers = Set(segments.map(\.speaker))
            var embeddings: [String: [Float]] = [:]

            for speakerId in uniqueSpeakers.sorted() {
                let speakerAudio = Self.extractSpeakerAudio(
                    samples: audioSamples,
                    segments: segments,
                    speakerId: speakerId,
                    sampleRate: Self.embeddingSampleRate,
                )
                guard speakerAudio.count >= Int(Self.embeddingSampleRate) else {
                    logger.warning("Skipping embedding for \(speakerId): audio too short")
                    continue
                }
                // swiftlint:disable:next force_unwrapping
                let embedding = try embeddingManager!.extractSpeakerEmbedding(from: speakerAudio)
                embeddings[speakerId] = embedding
            }

            logger.info("Extracted embeddings for \(embeddings.count)/\(uniqueSpeakers.count) speakers")
            return embeddings.isEmpty ? nil : embeddings
        } catch {
            logger.warning("Embedding extraction failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Slice audio samples for a specific speaker based on diarization segments.
    private static func extractSpeakerAudio(
        samples: [Float],
        segments: [MeetingTranscriber.DiarizationResult.Segment],
        speakerId: String,
        sampleRate: Float,
    ) -> [Float] {
        var speakerSamples: [Float] = []
        for seg in segments where seg.speaker == speakerId {
            let startSample = Int(seg.start * Double(sampleRate))
            let endSample = min(Int(seg.end * Double(sampleRate)), samples.count)
            guard startSample < endSample, startSample < samples.count else { continue }
            speakerSamples.append(contentsOf: samples[startSample ..< endSample])
        }
        return speakerSamples
    }
}
