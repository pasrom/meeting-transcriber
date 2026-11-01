import Foundation

/// Decides what a replace of an existing Notion page has to write and delete,
/// from the page's current root blocks alone.
///
/// A replace appends the new blocks and then deletes the old ones, so an
/// interrupted run leaves `[old blocks still to delete] + [the complete new
/// copy]`. Nothing marks the boundary: Notion blocks carry no custom data and
/// the client lives for one export, so the retry cannot remember it. Without
/// recognising the copy, every retry would list both halves as "old", append a
/// further full copy and delete only what it had listed, which is why an
/// aborted pass used to cost one more copy of the protocol each time.
///
/// The recognition is by visible content: block type and plain text, compared
/// from the end of the page. It is deliberately conservative:
/// - something must precede the matching run (`existing.count > replacement.count`),
///   so a page that merely equals the new content is replaced as before and a
///   re-export never skips on the strength of a single comparison;
/// - any difference falls back to appending a fresh copy, which converges on
///   the first pass that deletes cleanly.
/// Formatting, table cells and toggle children are not compared, so a retry
/// that differs from the interrupted run only there, and only while leftovers
/// exist, keeps the interrupted run's version of those parts.
struct NotionReplacePlan: Equatable {
    /// Root blocks to delete once the new content is on the page.
    let staleBlockIDs: [String]
    /// False when the page already ends with a complete copy of the new content.
    let needsAppend: Bool

    init(existing: [NotionBlockSummary], replacement: [NotionBlock]) {
        // The cheap length test comes first: the first export and a plain
        // re-export never reach the per-block encode.
        if !replacement.isEmpty,
           existing.count > replacement.count,
           Self.endsWithCopy(existing, of: replacement) {
            staleBlockIDs = existing.dropLast(replacement.count).map(\.id)
            needsAppend = false
        } else {
            staleBlockIDs = existing.map(\.id)
            needsAppend = true
        }
    }

    private static func endsWithCopy(_ existing: [NotionBlockSummary], of replacement: [NotionBlock]) -> Bool {
        zip(existing.suffix(replacement.count), replacement).allSatisfy { summary, block in
            Signature(block).map { $0 == Signature(summary) } ?? false
        }
    }

    /// Type and visible text of one root block, from either side of the API.
    private struct Signature: Equatable {
        let type: String
        let text: String

        init(_ summary: NotionBlockSummary) {
            type = summary.type ?? ""
            text = summary.text
        }

        /// Reads the text back out of the request body, the same JSON Notion
        /// receives, so it cannot drift from what is actually sent.
        init?(_ block: NotionBlock) {
            guard let data = try? JSONEncoder().encode(block),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            type = block.type
            let richText = (object[block.type] as? [String: Any])?["rich_text"] as? [[String: Any]]
            text = richText?.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined() ?? ""
        }
    }
}
