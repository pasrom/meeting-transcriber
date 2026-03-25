import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidVAD")

/// Maps timestamps from trimmed (VAD-filtered) audio back to original audio time.
///
/// When VAD removes silence, transcription/diarization timestamps are relative to the
/// shorter trimmed audio. This map converts them back to wall-clock time.
struct VadSegmentMap: Sendable {
    struct Entry: Sendable {
        /// Start time in the original audio.
        let originalStart: TimeInterval
        /// End time in the original audio.
        let originalEnd: TimeInterval
        /// Offset where this segment begins in the trimmed audio.
        let trimmedStart: TimeInterval

        var duration: TimeInterval { originalEnd - originalStart }
    }

    let entries: [Entry]

    /// Total duration of the trimmed audio (sum of all speech segments).
    let totalTrimmedDuration: TimeInterval

    /// Whether any speech was detected.
    var hasSpeech: Bool { !entries.isEmpty }

    /// Convert a timestamp from trimmed-audio space to original-audio space.
    ///
    /// Uses binary search to find the containing segment, then applies the offset.
    /// Clamps to nearest segment boundary for timestamps in gaps.
    func mapToOriginal(_ trimmedTime: TimeInterval) -> TimeInterval {
        guard !entries.isEmpty else { return trimmedTime }

        // Find the segment containing this trimmed time
        var lo = 0
        var hi = entries.count - 1

        while lo <= hi {
            let mid = (lo + hi) / 2
            let entry = entries[mid]
            let trimmedEnd = entry.trimmedStart + entry.duration

            if trimmedTime < entry.trimmedStart {
                hi = mid - 1
            } else if trimmedTime > trimmedEnd {
                lo = mid + 1
            } else {
                // Inside this segment
                let offset = trimmedTime - entry.trimmedStart
                return entry.originalStart + offset
            }
        }

        // Trimmed time is beyond all segments — clamp to end of last
        if lo >= entries.count {
            let last = entries[entries.count - 1]
            return last.originalEnd
        }
        // Before first segment — clamp to start
        return entries[0].originalStart
    }

    /// Build a segment map from VAD speech segments.
    static func build(from segments: [VadSegment]) -> VadSegmentMap {
        var entries: [Entry] = []
        var trimmedOffset: TimeInterval = 0

        for seg in segments {
            entries.append(Entry(
                originalStart: seg.startTime,
                originalEnd: seg.endTime,
                trimmedStart: trimmedOffset
            ))
            trimmedOffset += seg.endTime - seg.startTime
        }

        return VadSegmentMap(entries: entries, totalTrimmedDuration: trimmedOffset)
    }
}

/// On-device Voice Activity Detection using FluidAudio's VadManager (Silero VAD v6, CoreML).
///
/// Follows the same lightweight wrapper pattern as `FluidDiarizer`.
class FluidVAD {
    private var manager: VadManager?
    private let threshold: Float

    init(threshold: Float = VadConfig.default.defaultThreshold) {
        self.threshold = threshold
    }

    /// Initialize the VAD model (downloads on first use, ~few MB).
    func prepare() async throws {
        guard manager == nil else { return }
        let config = VadConfig(defaultThreshold: threshold)
        let mgr = try await VadManager(config: config)
        manager = mgr
        logger.info("VAD model ready (threshold: \(self.threshold))")
    }

    /// Run VAD on 16kHz mono Float32 samples. Returns speech segments.
    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment] {
        guard let mgr = manager else {
            throw VadError.notInitialized
        }
        return try await mgr.segmentSpeech(samples)
    }

    /// Run VAD on a 16kHz WAV file and produce a trimmed audio file containing only speech.
    ///
    /// - Parameters:
    ///   - inputPath: Path to 16kHz mono WAV file.
    ///   - outputPath: Where to write the trimmed WAV.
    /// - Returns: Segment map for timestamp remapping, or `nil` if no speech detected.
    func trimSilence(inputPath: URL, outputPath: URL) async throws -> VadSegmentMap? {
        let samples = try AudioMixer.loadAudioFileAsFloat32(url: inputPath)

        guard !samples.isEmpty else {
            logger.warning("Empty audio file: \(inputPath.lastPathComponent)")
            return nil
        }

        let segments = try await segmentSpeech(samples)

        guard !segments.isEmpty else {
            logger.info("No speech detected in \(inputPath.lastPathComponent)")
            return nil
        }

        let speechRanges: [(start: TimeInterval, end: TimeInterval)] = segments.map {
            (start: $0.startTime, end: $0.endTime)
        }

        let trimmedSamples = AudioMixer.extractSegments(
            from: samples,
            sampleRate: AudioMixer.transcriptionSampleRate,
            segments: speechRanges
        )

        try AudioMixer.saveWAV(
            samples: trimmedSamples,
            sampleRate: AudioMixer.transcriptionSampleRate,
            url: outputPath
        )

        let map = VadSegmentMap.build(from: segments)
        let trimmedPct = Int((1.0 - map.totalTrimmedDuration / (Double(samples.count) / Double(AudioMixer.transcriptionSampleRate))) * 100)
        logger.info(
            "VAD: \(inputPath.lastPathComponent) → \(segments.count) segments, "
                + "removed \(trimmedPct)% silence"
        )

        return map
    }
}
