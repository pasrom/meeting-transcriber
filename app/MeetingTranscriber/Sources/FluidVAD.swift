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
///
/// `@unchecked Sendable` because `PipelineQueue` caches a single instance
/// and reuses it across jobs, and live transcription shares one instance
/// across the mic + app `StreamingTranscriber` actors that call
/// `detectSpeech` concurrently. The mutable `manager` / `loadingTask`
/// fields are protected by `loadLock`; concurrent first callers all
/// await the same single-flight `Task` instead of racing on lazy init.
final class FluidVAD: @unchecked Sendable {
    private static let mergeGapSeconds: TimeInterval = 0.3
    private static let minRegionSeconds: TimeInterval = 0.15

    private let threshold: Float
    private let loadLock = NSLock()
    private var manager: VadManager?
    private var loadingTask: Task<VadManager, any Error>?

    init(threshold: Float = 0.5) {
        self.threshold = threshold
    }

    private enum LoadStep {
        case ready(VadManager)
        case pending(Task<VadManager, any Error>)
    }

    /// Ensure the VadManager is loaded, creating it lazily on first use.
    /// Safe to call concurrently from multiple tasks — the first caller
    /// kicks off the load, the rest await the same `Task`. Without this
    /// dedupe, two parallel first calls race on `manager` (TSan-visible)
    /// and trigger duplicate CoreML compiles of the Silero model.
    ///
    /// On failure the shared `Task` is dropped so the next call retries
    /// from scratch (mirrors `ParakeetEngine.loadModel()`). An awaiter
    /// being cancelled only cancels its own `await`; the underlying load
    /// continues so other awaiters still receive the manager.
    private func ensureManager() async throws -> VadManager {
        switch nextLoadStep() {
        case let .ready(mgr): mgr
        case let .pending(task): try await task.value
        }
    }

    /// Synchronous helper so `NSLock` never spans an async suspension.
    private func nextLoadStep() -> LoadStep {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let manager { return .ready(manager) }
        if let existing = loadingTask { return .pending(existing) }
        let threshold = self.threshold
        let task = Task<VadManager, any Error> { [weak self] in
            let config = VadConfig(defaultThreshold: threshold)
            do {
                let mgr = try await VadManager(config: config)
                self?.commitLoaded(mgr)
                return mgr
            } catch {
                // Drop the failed Task so the next caller retries; without
                // this, every future caller awaits the same poisoned Task
                // and re-throws the original error for the process lifetime.
                self?.clearLoadingTask()
                throw error
            }
        }
        loadingTask = task
        return .pending(task)
    }

    private func commitLoaded(_ mgr: VadManager) {
        loadLock.lock()
        manager = mgr
        loadingTask = nil
        loadLock.unlock()
        logger.info("VAD model loaded (threshold: \(self.threshold))")
    }

    private func clearLoadingTask() {
        loadLock.lock()
        defer { loadLock.unlock() }
        loadingTask = nil
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
        let trimRatio = totalDuration > 0 ? (1.0 - speechDuration / totalDuration) : 0
        let trimRatioStr = String(format: "%.2f", trimRatio)
        logger.info(
            "vad_extract regions=\(regions.count, privacy: .public) speech=\(speechStr, privacy: .public)s total=\(totalStr, privacy: .public)s trimRatio=\(trimRatioStr, privacy: .public)",
        )

        let map = VadSegmentMap(segments: regions, sampleRate: AudioConstants.targetSampleRate)

        // Round-trip sanity: pick the midpoint of the trimmed timeline, map back
        // to the original timeline, verify the result lands inside one of the
        // detected speech regions. If it doesn't, the mapping is inconsistent.
        if !regions.isEmpty {
            let probe = speechDuration / 2.0
            let mapped = map.toOriginalTime(probe)
            let inRegion = regions.contains { mapped >= $0.start && mapped <= $0.end }
            if !inRegion {
                let probeStr = String(format: "%.3f", probe)
                let mappedStr = String(format: "%.3f", mapped)
                logger.warning(
                    "vad_roundtrip_drift probe=\(probeStr, privacy: .public)s mapped=\(mappedStr, privacy: .public)s — VadSegmentMap may be inconsistent",
                )
            }
        }

        return map
    }

    // MARK: - Streaming API (live transcription)

    /// Opaque state threaded across consecutive `processStreamingChunk` calls.
    /// Callers must not introspect — pass back unchanged on the next call.
    typealias StreamState = VadStreamState

    /// A speech boundary detected by the streaming hysteresis state machine.
    /// Wraps `FluidAudio.VadStreamEvent` so callers don't have to import
    /// FluidAudio just to switch on the event kind.
    struct StreamEvent: Equatable {
        enum Kind: Equatable {
            case speechStart
            case speechEnd
        }

        let kind: Kind
        /// Sample index (16 kHz) at which the boundary occurred, relative to
        /// the cumulative stream start (the same axis as `state.processedSamples`).
        let sampleIndex: Int
        /// Wall-clock time of the boundary when `returnSeconds: true`.
        let time: TimeInterval?
    }

    /// Construct a fresh streaming state mirroring Silero's `reset_states`.
    /// Threaded across `processStreamingChunk` calls — one per channel.
    func makeStreamState() async throws -> StreamState {
        let mgr = try await ensureManager()
        return await mgr.makeStreamState()
    }

    /// Process a single audio chunk (16 kHz mono Float32) and return the
    /// updated state plus an optional speech boundary event. Caller is
    /// responsible for delivering chunks at the model's expected size
    /// (`VadManager.chunkSize`, 4096 samples ≈ 256 ms at 16 kHz).
    func processStreamingChunk(
        _ chunk: [Float],
        state: StreamState,
    ) async throws -> (state: StreamState, event: StreamEvent?) {
        let mgr = try await ensureManager()
        let result = try await mgr.processStreamingChunk(
            chunk,
            state: state,
            returnSeconds: true,
            timeResolution: 2,
        )
        let event = result.event.map { ev in
            StreamEvent(
                kind: ev.kind == .speechStart ? .speechStart : .speechEnd,
                sampleIndex: ev.sampleIndex,
                time: ev.time,
            )
        }
        return (result.state, event)
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
