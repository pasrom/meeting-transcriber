import Foundation

/// Renames the speaker slot of rendered transcript lines
/// (`[MM:SS] Speaker: text`, see `TimestampedSegment.formattedLine`).
enum SpeakerSlotRename {
    /// - Parameters:
    ///   - mapping: diarization label to the name the user confirmed.
    ///   - autoNames: diarization label to the name the transcript currently
    ///     shows for it, when the matcher had recognised the speaker.
    static func apply(
        to transcript: String,
        mapping: [String: String],
        autoNames: [String: String],
    ) -> String {
        // What a slot shows now -> what it should show. Built once and applied
        // to each line once: renaming one name at a time over the whole text
        // lets a later rename hit the output of an earlier one, so swapping
        // two recognised speakers put both under one name.
        var renames: [String: String] = [:]
        for (label, name) in mapping where !name.isEmpty {
            if label != name { renames[label] = name }
            if let autoName = autoNames[label], autoName != label, autoName != name {
                renames[autoName] = name
            }
        }
        guard !renames.isEmpty else { return transcript }
        // The slot is matched up to its colon, so the colon is part of the
        // key and "Al" cannot take "Alice". Longest first still matters for a
        // name that itself contains a colon: "A: B" must win over "A".
        let slots = renames
            .map { (shown: $0.key + ":", new: $0.value) }
            .sorted { $0.shown.count > $1.shown.count }

        return transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let stampEnd = timestampEnd(of: line) else { return line }
                let rest = line[stampEnd...]
                guard let slot = slots.first(where: { rest.hasPrefix($0.shown) }) else { return line }
                return line[..<stampEnd] + slot.new + ":" + rest.dropFirst(slot.shown.count)
            }
            .joined(separator: "\n")
    }

    /// End of a leading `[MM:SS] ` or `[H:MM:SS] ` stamp, the only shapes
    /// `TimestampedSegment.formattedTimestamp` writes. Nil for any other line:
    /// the bracketed recording note, or a continuation line of a multi-line
    /// segment that opens with a tag such as `[Music]`.
    private static func timestampEnd(of line: Substring) -> Substring.Index? {
        guard line.hasPrefix("["), let close = line.range(of: "] ") else { return nil }
        let fields = line[line.index(after: line.startIndex) ..< close.lowerBound].split(
            separator: ":", omittingEmptySubsequences: false,
        )
        guard (2 ... 3).contains(fields.count),
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        return close.upperBound
    }
}
