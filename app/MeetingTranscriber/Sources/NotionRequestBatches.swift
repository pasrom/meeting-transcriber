import Foundation

/// Keeps each request inside Notion's documented limits, so a long meeting cannot
/// fail identically on every retry. Nested blocks count towards the element limit.
enum NotionRequestBatches {
    static let maxBlocks = 100
    static let maxElements = 1000
    /// Notion allows 500 KB; the margin covers the rest of the request body.
    static let maxBytes = 450_000

    static func split(_ blocks: [NotionBlock]) throws -> [[NotionBlock]] {
        var batches: [[NotionBlock]] = []
        var current: [NotionBlock] = []
        var elements = 0
        var bytes = 0
        for block in blocks {
            let data = try JSONEncoder().encode(block)
            let blockElements = try 1 + nestedElementCount(in: JSONSerialization.jsonObject(with: data))
            let fits = current.count < maxBlocks
                && elements + blockElements <= maxElements
                && bytes + data.count <= maxBytes
            if !fits, !current.isEmpty {
                batches.append(current)
                current = []
                elements = 0
                bytes = 0
            }
            current.append(block)
            elements += blockElements
            bytes += data.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private static func nestedElementCount(in value: Any) -> Int {
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + nestedElementCount(in: $1) }
        }
        guard let object = value as? [String: Any] else { return 0 }
        return object.reduce(0) { total, entry in
            let own = entry.key == "children" ? (entry.value as? [Any])?.count ?? 0 : 0
            return total + own + nestedElementCount(in: entry.value)
        }
    }
}
