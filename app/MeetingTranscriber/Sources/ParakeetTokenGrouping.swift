import FluidAudio
import Foundation

/// Pure token-grouping logic for Parakeet ASR output.
///
/// Extracted from `ParakeetEngine` so the segmentation rules (sentence-end
/// punctuation, soft 20-token cap) can be unit-tested without loading a model.
enum ParakeetTokenGrouping {
    /// Target maximum tokens per segment before splitting at the next word boundary.
    ///
    /// The cap is soft because Parakeet can emit partial-word tokens. Splitting
    /// immediately at the token limit can turn `normally` into `norm ally` when
    /// segment texts are joined later.
    static let maxTokensPerSegment = 20

    private static let whitespace = CharacterSet.whitespacesAndNewlines

    /// Group token-level timings into sentence-level `TimestampedSegment`s.
    ///
    /// Ends a segment at sentence-terminating punctuation (`. ! ?`) or
    /// after `maxTokensPerSegment` tokens once a word boundary is reached.
    /// Tokens that are blank after whitespace-trimming are skipped entirely.
    static func groupIntoSegments(_ timings: [TokenTiming]) -> [TimestampedSegment] {
        var segments: [TimestampedSegment] = []
        var group: [TokenTiming] = []

        for (index, timing) in timings.enumerated() {
            let token = timing.token
            guard !isBlank(token) else { continue }
            group.append(timing)

            let endsWithPunct = token.hasSuffix(".") || token.hasSuffix("!") || token.hasSuffix("?")
            let nextBoundary = nextTokenBoundary(after: index, in: timings)
            let canSplitAtTokenCap = group.count >= maxTokensPerSegment
                && isWordBoundary(
                    after: token,
                    before: nextBoundary.token,
                    hasWhitespaceSeparator: nextBoundary.hasWhitespaceSeparator,
                )
            if endsWithPunct || canSplitAtTokenCap {
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
        let text = timings.map(\.token).joined().trimmingCharacters(in: whitespace)
        guard !text.isEmpty else { return nil }
        // swiftlint:disable:next force_unwrapping
        return TimestampedSegment(start: timings.first!.startTime, end: timings.last!.endTime, text: text)
    }

    private static func isBlank(_ token: String) -> Bool {
        token.trimmingCharacters(in: whitespace).isEmpty
    }

    private static func nextTokenBoundary(
        after index: Int,
        in timings: [TokenTiming],
    ) -> (token: String?, hasWhitespaceSeparator: Bool) {
        var hasWhitespaceSeparator = false
        var nextIndex = index + 1

        while nextIndex < timings.count {
            let token = timings[nextIndex].token
            if isBlank(token) {
                hasWhitespaceSeparator = hasWhitespaceSeparator
                    || token.unicodeScalars.contains(where: whitespace.contains)
                nextIndex += 1
                continue
            }
            return (token, hasWhitespaceSeparator)
        }

        return (nil, hasWhitespaceSeparator)
    }

    private static func isWordBoundary(
        after token: String,
        before nextToken: String?,
        hasWhitespaceSeparator: Bool,
    ) -> Bool {
        if hasWhitespaceSeparator { return true }
        guard let nextToken else { return true }
        return token.unicodeScalars.last.map(whitespace.contains) == true
            || nextToken.unicodeScalars.first.map(whitespace.contains) == true
    }
}
