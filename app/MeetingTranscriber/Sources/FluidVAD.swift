import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FluidVAD")

// MARK: - VADConfig

/// Configuration for Voice Activity Detection.
/// Used by PipelineQueue: `nil` means disabled, non-nil means enabled.
struct VADConfig {
    let threshold: Float
}

// MARK: - SpeechRegion

/// A contiguous region of detected speech.
struct SpeechRegion {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        end - start
    }
}

// MARK: - VadSegmentMap

/// Maps between trimmed (speech-only) and original audio timelines.
/// Pure value type — no FluidAudio dependency, fully testable.
struct VadSegmentMap {
    let segments: [SpeechRegion]
    let sampleRate: Int

    /// Duration of the original audio (last segment's end, or 0).
    var originalDuration: TimeInterval {
        segments.last?.end ?? 0
    }

    /// Total duration of speech-only audio.
    var trimmedDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// Convert a timestamp in trimmed audio back to the original timeline.
    func toOriginalTime(_ trimmedTime: TimeInterval) -> TimeInterval {
        var remaining = trimmedTime
        for segment in segments {
            let segDuration = segment.duration
            if remaining <= segDuration {
                return segment.start + remaining
            }
            remaining -= segDuration
        }
        // Past end — return last segment's end
        return segments.last?.end ?? trimmedTime
    }

    /// Remap transcript segment timestamps from trimmed back to original timeline.
    func remapTimestamps(_ transcript: [TimestampedSegment]) -> [TimestampedSegment] {
        transcript.map { seg in
            TimestampedSegment(
                start: toOriginalTime(seg.start),
                end: toOriginalTime(seg.end),
                text: seg.text,
                speaker: seg.speaker,
            )
        }
    }

    /// Extract speech-only samples from the full audio buffer.
    func extractSpeechSamples(from audio: [Float]) -> [Float] {
        let totalSamples = segments.reduce(0) { acc, seg in
            acc + max(0, Int(seg.end * Double(sampleRate)) - Int(seg.start * Double(sampleRate)))
        }
        var result: [Float] = []
        result.reserveCapacity(totalSamples)
        for segment in segments {
            let startSample = Int(segment.start * Double(sampleRate))
            let endSample = min(Int(segment.end * Double(sampleRate)), audio.count)
            guard startSample < endSample, startSample < audio.count else { continue }
            result.append(contentsOf: audio[startSample ..< endSample])
        }
        return result
    }
}

// MARK: - FluidVAD

/// Voice Activity Detection using FluidAudio's Silero VAD v6.
/// Lazily creates VadManager on first use.
class FluidVAD {
    private static let mergeGapSeconds: TimeInterval = 0.3
    private static let minRegionSeconds: TimeInterval = 0.15

    private let threshold: Float
    private var manager: VadManager?

    init(threshold: Float = 0.5) {
        self.threshold = threshold
    }

    /// Ensure the VadManager is loaded, creating it lazily on first use.
    private func ensureManager() async throws -> VadManager {
        if let manager { return manager }
        let config = VadConfig(defaultThreshold: threshold)
        let mgr = try await VadManager(config: config)
        manager = mgr
        logger.info("VAD model loaded (threshold: \(self.threshold))")
        return mgr
    }

    /// Detect speech regions from pre-loaded audio samples (16kHz Float32).
    func detectSpeech(samples: [Float]) async throws -> VadSegmentMap {
        let mgr = try await ensureManager()
        let results = try await mgr.process(samples)
        return buildSegmentMap(from: results)
    }

    /// Convert per-chunk VAD results into merged, filtered speech regions.
    private func buildSegmentMap(from results: [VadResult]) -> VadSegmentMap {
        let chunkDuration = Double(VadManager.chunkSize) / Double(VadManager.sampleRate) // ~0.256s
        var regions: [SpeechRegion] = []
        var speechStart: TimeInterval?

        for (index, result) in results.enumerated() {
            let chunkTime = Double(index) * chunkDuration
            if result.probability >= threshold {
                if speechStart == nil {
                    speechStart = chunkTime
                }
            } else if let start = speechStart {
                regions.append(SpeechRegion(start: start, end: chunkTime))
                speechStart = nil
            }
        }
        // Close any open region
        if let start = speechStart {
            let endTime = Double(results.count) * chunkDuration
            regions.append(SpeechRegion(start: start, end: endTime))
        }

        regions = mergeCloseRegions(regions, maxGap: Self.mergeGapSeconds)
        regions = regions.filter { $0.duration >= Self.minRegionSeconds }

        let totalDuration = Double(results.count) * chunkDuration
        let speechDuration = regions.reduce(0.0) { $0 + $1.duration }
        let speechStr = String(format: "%.1f", speechDuration)
        let totalStr = String(format: "%.1f", totalDuration)
        logger.info("VAD: \(regions.count) speech regions, \(speechStr)s speech / \(totalStr)s total")

        return VadSegmentMap(segments: regions, sampleRate: AudioConstants.targetSampleRate)
    }

    /// Merge regions that are closer together than maxGap seconds.
    private func mergeCloseRegions(_ regions: [SpeechRegion], maxGap: TimeInterval) -> [SpeechRegion] {
        guard !regions.isEmpty else { return [] }
        var merged: [SpeechRegion] = [regions[0]]
        for region in regions.dropFirst() {
            // swiftlint:disable:next force_unwrapping
            let last = merged.last!
            if region.start - last.end < maxGap {
                merged[merged.count - 1] = SpeechRegion(start: last.start, end: region.end)
            } else {
                merged.append(region)
            }
        }
        return merged
    }
}
