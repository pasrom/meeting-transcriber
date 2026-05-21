import Foundation

/// Pure chunking logic for `Qwen3AsrEngine` audio segmentation.
///
/// Qwen3-ASR's stateful decoder caps each call at `Qwen3AsrConfig.maxAudioSeconds`
/// (30 s at 16 kHz). Long audio is split into back-to-back chunks of at most
/// that size and transcribed one chunk per call. Extracting the index math
/// makes it testable without a model.
enum Qwen3AsrChunking {
    /// Compute the sample-index ranges that partition `totalCount` samples
    /// into contiguous, non-overlapping chunks of at most `maxSamples` each.
    ///
    /// - Ranges are returned in order.
    /// - The final range may be shorter than `maxSamples`.
    /// - Returns `[]` for zero-length input.
    ///
    /// Precondition: `maxSamples > 0`.
    static func chunkRanges(totalCount: Int, maxSamples: Int) -> [Range<Int>] {
        precondition(maxSamples > 0, "maxSamples must be positive")
        guard totalCount > 0 else { return [] }
        var ranges: [Range<Int>] = []
        var offset = 0
        while offset < totalCount {
            let end = min(offset + maxSamples, totalCount)
            ranges.append(offset ..< end)
            offset = end
        }
        return ranges
    }
}
