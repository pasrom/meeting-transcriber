import Foundation

/// Text-only boundaries over a prefix-monotonic cumulative transcript; never resets the decoder.
struct StreamingCaptionSplitter {
    static let defaultMaxWords = 14
    static let defaultPauseSeconds: TimeInterval = 0.7

    struct Update {
        var finals: [String]
        var hypothesis: String
    }

    let maxWords: Int
    let pauseSeconds: TimeInterval
    private var committedCharacters = 0
    private var lastTranscript = ""
    /// Audio time of the last transcript change: where a pause-closed line's speech ends.
    private(set) var changedAt: TimeInterval = 0

    init(maxWords: Int = defaultMaxWords, pauseSeconds: TimeInterval = defaultPauseSeconds) {
        precondition(maxWords > 0)
        self.maxWords = maxWords
        self.pauseSeconds = pauseSeconds
    }

    mutating func update(_ transcript: String, audioTime: TimeInterval, finalize: Bool = false) -> Update {
        if transcript != lastTranscript {
            lastTranscript = transcript
            changedAt = audioTime
        }
        let pending = transcript.dropFirst(committedCharacters)
        let words = pending.split(whereSeparator: \.isWhitespace)
        // The last token may still be growing; require its following word boundary.
        let completeWords = words.count - (pending.last?.isWhitespace == false ? 1 : 0)
        var finals: [String] = []
        var start = 0
        while start + maxWords <= completeWords {
            let end = words[start + maxWords - 1].endIndex
            finals.append(String(transcript[words[start].startIndex ..< end]))
            committedCharacters = transcript.distance(from: transcript.startIndex, to: end)
            start += maxWords
        }
        var hypothesis = String(transcript.dropFirst(committedCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !hypothesis.isEmpty, finalize || audioTime - changedAt >= pauseSeconds {
            finals.append(hypothesis)
            committedCharacters = transcript.count
            hypothesis = ""
        }
        return Update(finals: finals, hypothesis: hypothesis)
    }

    /// Commits the uncommitted words of `prefix`, an earlier state of the running transcript, as one
    /// line: the voice changed after them. A word the running transcript continues goes to the next line.
    mutating func cut(_ prefix: String) -> String? {
        var endOffset = prefix.count
        if prefix.last?.isWhitespace == false, lastTranscript.hasPrefix(prefix),
           lastTranscript.dropFirst(endOffset).first?.isWhitespace == false {
            endOffset = prefix.lastIndex(where: \.isWhitespace).map { prefix.distance(from: prefix.startIndex, to: $0) } ?? 0
        }
        guard endOffset > committedCharacters else { return nil }
        let line = String(prefix.dropFirst(committedCharacters).prefix(endOffset - committedCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        committedCharacters = endOffset
        return line.isEmpty ? nil : line
    }

    mutating func reset() {
        committedCharacters = 0
        lastTranscript = ""
        changedAt = 0
    }
}
