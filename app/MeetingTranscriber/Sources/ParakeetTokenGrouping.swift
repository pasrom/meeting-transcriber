import FluidAudio
import Foundation

/// Pure token-grouping logic for Parakeet ASR output.
///
/// Extracted from `ParakeetEngine` so the segmentation rules (sentence-end
/// punctuation, 20-token cap) can be unit-tested without loading a model.
enum ParakeetTokenGrouping {
    /// Maximum tokens per segment before forcing a split — keeps segments
    /// short enough that they remain useful for the protocol generator
    /// even when the model emits long runs without terminal punctuation.
    static let maxTokensPerSegment = 20

    /// Group token-level timings into sentence-level `TimestampedSegment`s.
    ///
    /// Ends a segment at sentence-terminating punctuation (`. ! ?`) or
    /// after `maxTokensPerSegment` tokens, whichever comes first. Tokens
    /// that are blank after whitespace-trimming are skipped entirely.
    static func groupIntoSegments(_ timings: [TokenTiming]) -> [TimestampedSegment] {
        var segments: [TimestampedSegment] = []
        var group: [TokenTiming] = []

        for timing in timings {
            let token = timing.token
            guard !token.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty else { continue }
            group.append(timing)

            let endsWithPunct = token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?")
            if endsWithPunct || group.count >= maxTokensPerSegment {
                if let seg = makeSegment(from: group) { segments.append(seg) }
                group = []
            }
        }
        if let seg = makeSegment(from: group) { segments.append(seg) }

        return segments
    }

    /// Build a `TimestampedSegment` from a contiguous group of token timings.
    /// Returns nil if `timings` is empty or yields an all-whitespace text.
    static func makeSegment(from timings: [TokenTiming]) -> TimestampedSegment? {
        guard !timings.isEmpty else { return nil }
        let text = timings.map(\.token).joined().trimmingCharacters(in: CharacterSet.whitespaces)
        guard !text.isEmpty else { return nil }
        // swiftlint:disable:next force_unwrapping
        return TimestampedSegment(start: timings.first!.startTime, end: timings.last!.endTime, text: text)
    }
}
