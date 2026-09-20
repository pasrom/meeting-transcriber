import Foundation

/// A transcribed segment with timestamps and optional speaker label.
///
/// Every field is `var` on purpose: downstream passes (delay shift, VAD
/// remap, block merge) adjust one or two fields on an existing value, and
/// copy-and-mutate is what keeps the fields they do NOT touch. A memberwise
/// rebuild instead silently resets whatever it forgot to pass — that is how
/// the delay shift once dropped `suppressed` and reintroduced the very
/// duplicates it marks (issue #581).
struct TimestampedSegment: Codable {
    var start: TimeInterval // seconds
    var end: TimeInterval // seconds
    var text: String
    var speaker: String = ""
    /// Set when this microphone segment is the loudspeaker output coming back
    /// through the microphone, i.e. a second copy of something the app track
    /// already carries. Left in place rather than deleted: the words are still
    /// recoverable from the stored segments, and diarization still sees the
    /// timing. Only the rendered transcript leaves them out.
    var suppressed: Bool = false

    /// Spelled out because a synthesized decoder requires every key, defaults or
    /// not. `suppressed` is new on a shape that is already persisted in speaker
    /// naming data, and a throwing decode there would discard the whole file and
    /// with it a job's pending naming.
    init(start: TimeInterval, end: TimeInterval, text: String, speaker: String = "", suppressed: Bool = false) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.suppressed = suppressed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        suppressed = try container.decodeIfPresent(Bool.self, forKey: .suppressed) ?? false
    }
}

extension [TimestampedSegment] {
    /// The transcript as written to disk, without the segments that are only the
    /// loudspeaker coming back, and under the recording-level note when there is
    /// one. One helper rather than a filter at each of the three rendering
    /// sites, so a fourth cannot quietly reintroduce the duplicates. The note
    /// rides here for that same reason, and `note` has no default so a site
    /// with nothing to add says `nil` rather than forgets: applying it at each
    /// *write* site instead missed the mid-pipeline draft.
    func transcriptText(note: String?) -> String {
        TranscriptNote.prepend(
            note, to: filter { !$0.suppressed }.map(\.formattedLine).joined(separator: "\n"),
        )
    }
}

extension TimestampedSegment {
    /// A copy moved by `offset` seconds. The one sanctioned way to put a
    /// segment on a different timeline: it touches nothing but the two
    /// timestamps, so a field added to the type later travels along instead
    /// of resetting to its default.
    func shifted(by offset: TimeInterval) -> TimestampedSegment {
        var copy = self
        copy.start += offset
        copy.end += offset
        return copy
    }

    /// Format timestamp as [MM:SS] or [H:MM:SS] for long recordings.
    var formattedTimestamp: String {
        let total = Int(start)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "[%d:%02d:%02d]", h, m, s)
            : String(format: "[%02d:%02d]", m, s)
    }

    /// Format as "[MM:SS] Speaker: text" or "[MM:SS] text" if no speaker.
    var formattedLine: String {
        let ts = formattedTimestamp
        if speaker.isEmpty {
            return "\(ts) \(text)"
        }
        return "\(ts) \(speaker): \(text)"
    }
}
