import Foundation

/// Keeps each request inside Notion's documented limits, so a long meeting cannot
/// fail identically on every retry. Nested blocks count towards the element limit.
///
/// A block is never cut here: `MarkdownToNotionBlocks` builds blocks that fit on their
/// own. One that still breaks a limit is refused with `NotionBlockTooLargeError`, because
/// sending it would fail with the same 400 on every retry.
enum NotionRequestBatches {
    static let maxBlocks = 100
    static let maxElements = 1000
    /// Notion allows 500 KB; the margin covers the rest of the request body.
    static let maxBytes = 450_000
    /// Documented ceiling of one `children` array and of one `rich_text` array.
    static let maxArrayCount = 100
    /// Documented ceiling of one rich text item's content. Counted in UTF-16 units,
    /// the reading that is safe whichever way Notion counts.
    static let maxTextUnits = 2000

    static func split(_ blocks: [NotionBlock]) throws -> [[NotionBlock]] {
        var batches: [[NotionBlock]] = []
        var current: [NotionBlock] = []
        var elements = 0
        var bytes = 0
        for block in blocks {
            let data = try JSONEncoder().encode(block)
            let json = try JSONSerialization.jsonObject(with: data)
            let blockElements = 1 + nestedElementCount(in: json)
            guard data.count <= maxBytes, blockElements <= maxElements, !breaksFieldLimit(json) else {
                throw NotionBlockTooLargeError()
            }
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

    /// True when an array or text inside the block is over the limit that Notion applies to it:
    /// `children`, `rich_text`, a table row's cells, and the content of a text item.
    private static func breaksFieldLimit(_ value: Any, key: String? = nil) -> Bool {
        if let array = value as? [Any] {
            if key == "children" || key == "rich_text", array.count > maxArrayCount { return true }
            if key == "cells", array.contains(where: { ($0 as? [Any])?.count ?? 0 > maxArrayCount }) { return true }
            return array.contains { breaksFieldLimit($0) }
        }
        guard let object = value as? [String: Any] else { return false }
        return object.contains { name, child in
            if name == "content", let text = child as? String, text.utf16.count > maxTextUnits { return true }
            return breaksFieldLimit(child, key: name)
        }
    }
}

/// A block that breaks a Notion limit on its own, so no batching can make it fit.
struct NotionBlockTooLargeError: Error, Equatable {}
