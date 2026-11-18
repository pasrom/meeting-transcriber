import Foundation

/// Non-overlapping model windows and approximate timestamps from CTC frames.
enum GigaAMSegmentation {
    /// Prefer a quiet 100 ms cut near the end of a full model window.
    static func chunkLength(_ samples: [Float], hasMore: Bool) -> Int {
        guard hasMore, samples.count == GigaAMModel.maxSamples else { return samples.count }
        let window = GigaAMModel.sampleRate / 10
        let search = 20 * window
        let end = samples.count
        var lowest = Float.infinity
        var boundary = end
        for start in stride(from: end - window, through: end - search, by: -window) {
            let energy = samples[start ..< start + window].reduce(Float(0)) { $0 + $1 * $1 }
            if energy < lowest {
                lowest = energy
                boundary = start + window / 2
            }
        }
        return boundary
    }

    static func text(_ pieces: [GigaAMModel.Piece]) -> String {
        pieces.map(\.text).joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func segments(_ pieces: [GigaAMModel.Piece], offset: Int, length: Int) -> [TimestampedSegment] {
        var result: [TimestampedSegment] = []
        var start = 0
        let rate = Double(GigaAMModel.sampleRate)
        let step = GigaAMModel.secondsPerToken
        let chunkOffset = Double(offset) / rate
        let chunkDuration = Double(length) / rate
        for index in pieces.indices {
            let piece = pieces[index]
            let next = index + 1
            let atEnd = next == pieces.endIndex
            let sentenceEnds = piece.text.last.map { ".!?".contains($0) } ?? false
            let nextWord = !atEnd && pieces[next].text.hasPrefix("▁")
            let gap = atEnd ? 0 : pieces[next].firstFrame - piece.endFrame
            guard atEnd || sentenceEnds || (nextWord && (gap >= 10 || index - start >= 19)) else { continue }
            let group = Array(pieces[start ... index])
            let phrase = text(group)
            if !phrase.isEmpty {
                result.append(TimestampedSegment(
                    start: chunkOffset + min(chunkDuration, Double(pieces[start].firstFrame) * step),
                    end: chunkOffset + min(chunkDuration, Double(piece.endFrame) * step),
                    text: phrase,
                ))
            }
            start = next
        }
        return result
    }
}
