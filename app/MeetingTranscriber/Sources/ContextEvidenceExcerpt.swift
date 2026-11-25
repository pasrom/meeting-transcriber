import Foundation

enum ContextEvidenceExcerpt {
    private struct Match {
        let text: String
        let line: Substring
        let score: Int
    }

    /// Keep complete evidence when it fits. For larger text results, keep one
    /// contiguous excerpt around the line that covers the most lookup terms.
    static func fit(_ content: ContextJSON, byteLimit: Int, mentions: [String]) throws -> ContextJSON {
        if try ContextJSON.encoded(content).count <= byteLimit { return content }
        guard byteLimit > 0, let parts = content.array else { throw ContextFailure.limit }
        let terms = Set(mentions.flatMap(words))
        guard let match = bestMatch(in: parts, terms: terms) else { throw ContextFailure.limit }
        return try fitExcerpt(match, terms: terms, byteLimit: byteLimit)
    }

    private static func words(_ text: some StringProtocol) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 2 }.map(String.init)
    }

    private static func bestMatch(in parts: [ContextJSON], terms: Set<String>) -> Match? {
        var best: Match?
        for part in parts {
            guard let text = part["text"]?.string else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let score = terms.intersection(words(line)).count
                if best == nil || score > (best?.score ?? 0) {
                    best = Match(text: text, line: line, score: score)
                }
            }
        }
        return best
    }

    private static func fitExcerpt(_ match: Match, terms: Set<String>, byteLimit: Int) throws -> ContextJSON {
        let text = match.text
        let matchingWords = match.line.split { !$0.isLetter && !$0.isNumber }
            .filter { terms.contains($0.lowercased()) }
        let matchIndex = matchingWords.max { $0.count < $1.count }?.startIndex ?? match.line.startIndex
        let offset = text.distance(from: text.startIndex, to: matchIndex)
        let count = text.count
        var lower = 1
        var upper = min(byteLimit, count)
        var fitted: ContextJSON?
        while lower <= upper {
            let length = (lower + upper) / 2
            let start = min(max(0, offset - length / 3), count - length)
            let first = text.index(text.startIndex, offsetBy: start)
            let last = text.index(first, offsetBy: length)
            let prefix = start > 0 ? "[…]\n" : ""
            let suffix = last < text.endIndex ? "\n[…]" : ""
            let excerpt = ContextJSON.array([.object([
                "text": .string(prefix + text[first ..< last] + suffix), "excerpted": .bool(true),
            ])])
            if try ContextJSON.encoded(excerpt).count <= byteLimit {
                fitted = excerpt
                lower = length + 1
            } else {
                upper = length - 1
            }
        }
        guard let fitted else { throw ContextFailure.limit }
        return fitted
    }
}
