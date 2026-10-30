import Foundation
@testable import MeetingTranscriber
import XCTest

final class MarkdownToNotionBlocksTests: XCTestCase {
    func testHeadingsConversion() {
        let md = """
        # Heading 1
        ## Heading 2
        ### Heading 3
        """
        let blocks = MarkdownToNotionBlocks.convert(markdown: md)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].type, "heading_1")
        XCTAssertEqual(blocks[1].type, "heading_2")
        XCTAssertEqual(blocks[2].type, "heading_3")
    }

    func testListsAndQuotesConversion() {
        let md = """
        - Bullet point 1
        * Bullet point 2
        1. Numbered item 1
        2. Numbered item 2
        > A wise quote
        ---
        """
        let blocks = MarkdownToNotionBlocks.convert(markdown: md)
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0].type, "bulleted_list_item")
        XCTAssertEqual(blocks[1].type, "bulleted_list_item")
        XCTAssertEqual(blocks[2].type, "numbered_list_item")
        XCTAssertEqual(blocks[3].type, "numbered_list_item")
        XCTAssertEqual(blocks[4].type, "quote")
        XCTAssertEqual(blocks[5].type, "divider")
    }

    func testTableConversion() {
        let md = """
        | Task | Assignee | Priority |
        | --- | --- | --- |
        | Setup CI | Alice | High |
        | Write Docs | Bob | Medium |
        """
        let blocks = MarkdownToNotionBlocks.convert(markdown: md)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, "table")
    }

    func testTableLikeLinesWithoutDelimiterRemainParagraphs() throws {
        let cases = [
            ["| Decision: ship it |"],
            ["| Task | Assignee |", "| Setup CI | Alice |"],
        ]
        for lines in cases {
            let blocks = MarkdownToNotionBlocks.convert(markdown: lines.joined(separator: "\n"))

            XCTAssertEqual(blocks.map(\.type), Array(repeating: "paragraph", count: lines.count))
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(blocks))
            let paragraphs = try XCTUnwrap(json as? [[String: Any]])
            let contents = try paragraphs.map { block -> String in
                let paragraph = try XCTUnwrap(block["paragraph"] as? [String: Any])
                let richText = try XCTUnwrap(paragraph["rich_text"] as? [[String: Any]])
                let text = try XCTUnwrap(richText.first?["text"] as? [String: Any])
                return try XCTUnwrap(text["content"] as? String)
            }
            XCTAssertEqual(contents, lines)
        }
    }

    func testTranscriptConvertedToToggleBlock() {
        let md = """
        # Meeting Minutes
        Summary of the meeting.
        """
        let transcript = """
        [Alice]: Hi team!
        [Bob]: Hello Alice, let's start.
        """
        let blocks = MarkdownToNotionBlocks.convert(markdown: md, transcript: transcript)
        XCTAssertTrue(blocks.count >= 3)
        let toggle = blocks.first { $0.type == "toggle" }
        XCTAssertNotNil(toggle, "Transcript should be converted into a toggle block")
    }

    func testLongTranscriptFirstLineAndMarkdownCharactersRemainVerbatim() throws {
        let firstLine = String(repeating: "A", count: 1201)
        let secondLine = "[Alice]: 2 * 3 * 4; press *enter*"
        let blocks = MarkdownToNotionBlocks.convert(markdown: "# Minutes", transcript: "\(firstLine)\n\(secondLine)")
        let toggle = try XCTUnwrap(blocks.first { $0.type == "toggle" })
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(toggle))
        let root = try XCTUnwrap(json as? [String: Any])
        let content = try XCTUnwrap(root["toggle"] as? [String: Any])
        let children = try XCTUnwrap(content["children"] as? [[String: Any]])

        XCTAssertEqual(children.count, 2)
        let paragraphs = try children.map { child -> [[String: Any]] in
            let paragraph = try XCTUnwrap(child["paragraph"] as? [String: Any])
            return try XCTUnwrap(paragraph["rich_text"] as? [[String: Any]])
        }
        let texts = try paragraphs.map { richText -> String in
            try richText.map { item -> String in
                let text = try XCTUnwrap(item["text"] as? [String: Any])
                return try XCTUnwrap(text["content"] as? String)
            }.joined()
        }
        XCTAssertEqual(texts, [firstLine, secondLine])
        XCTAssertTrue(paragraphs.flatMap(\.self).allSatisfy { $0["annotations"] == nil })
    }

    func testInlineFormattingInRichText() {
        let text = "This has **bold text**, *italic text*, and `code text`."
        let richText = MarkdownToNotionBlocks.makeRichText(text)
        XCTAssertGreaterThan(richText.count, 1)
    }

    func testLongTextIsSplitNotTruncated() throws {
        let veryLongText = String(repeating: "A", count: 5000)
        let richText = MarkdownToNotionBlocks.makeRichText(veryLongText)

        XCTAssertEqual(richText.count, 3)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(richText))
        let items = try XCTUnwrap(json as? [[String: Any]])
        let content = try items.map { item -> String in
            let text = try XCTUnwrap(item["text"] as? [String: Any])
            return try XCTUnwrap(text["content"] as? String)
        }
        XCTAssertEqual(content.joined(), veryLongText)
        XCTAssertTrue(content.allSatisfy { $0.count <= 2000 })
    }

    func testTableRowsAreEncodedAsBlockObjects() throws {
        let md = """
        | Task | Assignee |
        | --- | --- |
        | Setup CI | Alice |
        """
        let blocks = MarkdownToNotionBlocks.convert(markdown: md)
        let block = try XCTUnwrap(blocks.first)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(block))
        let root = try XCTUnwrap(json as? [String: Any])
        let table = try XCTUnwrap(root["table"] as? [String: Any])
        let rows = try XCTUnwrap(table["children"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["object"] as? String, "block")
        XCTAssertEqual(rows[0]["type"] as? String, "table_row")
    }

    func testTranscriptToggleFollowsExactlyOneDivider() {
        let explicit = MarkdownToNotionBlocks.convert(markdown: "## Open Questions\n- One", transcript: "[00:00] Hi")
        XCTAssertEqual(explicit.filter { $0.type == "divider" }.count, 1)

        let parsed = MarkdownToNotionBlocks.convert(markdown: "## Open Questions\n- One\n\n---\n\n## Full Transcript\n\n[00:00] Hi")
        XCTAssertEqual(parsed.filter { $0.type == "divider" }.count, 1)
    }

    func testTableOverNotionsChildLimitFallsBackToText() {
        let rows = (0 ..< 101).map { "| r\($0) |" }.joined(separator: "\n")
        let blocks = MarkdownToNotionBlocks.convert(markdown: "| h |\n|---|\n\(rows)")
        XCTAssertFalse(blocks.contains { $0.type == "table" })
        XCTAssertEqual(blocks.count, 103)
    }

    func testTableAtNotionsChildLimitStaysATable() {
        let rows = (0 ..< 99).map { "| r\($0) |" }.joined(separator: "\n")
        let blocks = MarkdownToNotionBlocks.convert(markdown: "| h |\n|---|\n\(rows)")
        XCTAssertEqual(blocks.map(\.type), ["table"])
    }

    func testBatchesStayInsideNotionsRequestLimits() throws {
        let transcript = (0 ..< 3000).map { "[\($0)] " + String(repeating: "word ", count: 60) }.joined(separator: "\n")
        let blocks = MarkdownToNotionBlocks.convert(markdown: "# Title", transcript: transcript)
        let batches = try NotionRequestBatches.split(blocks)

        XCTAssertEqual(batches.flatMap(\.self).count, blocks.count)
        XCTAssertGreaterThan(batches.count, 1)
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.count, NotionRequestBatches.maxBlocks)
            let data = try JSONEncoder().encode(batch)
            XCTAssertLessThanOrEqual(data.count, NotionRequestBatches.maxBytes)
        }
    }

    func testBatchSplitsOnNestedElementCount() throws {
        let lines = (0 ..< 95 * 12).map { "[\($0)] " + String(repeating: "x", count: 1190) }.joined(separator: "\n")
        let blocks = MarkdownToNotionBlocks.convert(markdown: "# Title", transcript: lines)
        XCTAssertEqual(blocks.filter { $0.type == "toggle" }.count, 12)
        XCTAssertGreaterThan(try NotionRequestBatches.split(blocks).count, 1)
    }
}
