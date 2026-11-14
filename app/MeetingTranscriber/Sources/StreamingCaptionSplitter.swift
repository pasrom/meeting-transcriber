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
    private var changedAt: TimeInterval = 0

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

    mutating func reset() {
        committedCharacters = 0
        lastTranscript = ""
        changedAt = 0
    }
}
