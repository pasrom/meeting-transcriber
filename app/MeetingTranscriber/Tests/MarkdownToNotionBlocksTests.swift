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

    /// The heading the converter reads a saved transcript from is the one the check looks for.
    func testFullTranscriptHeadingCheckAgreesWithTheConverter() {
        let withTranscript = "# Minutes\n\n---\n\n## Full Transcript\n\n[Alice]: Hi"
        let withoutTranscript = "# Minutes\n\nFull transcript attached separately.\n\n- full transcript"
        for (markdown, expected) in [(withTranscript, true), (withoutTranscript, false), ("  # FULL TRANSCRIPT\r\nx", true)] {
            XCTAssertEqual(MarkdownToNotionBlocks.hasFullTranscriptHeading(in: markdown), expected, markdown)
        }
        XCTAssertTrue(MarkdownToNotionBlocks.convert(markdown: withTranscript).contains { $0.type == "toggle" })
        XCTAssertFalse(MarkdownToNotionBlocks.convert(markdown: withoutTranscript).contains { $0.type == "toggle" })
        // A line break the converter does not split on is not a heading start for the check either.
        let unicodeBreak = "# Minutes\u{2028}## Full Transcript\n"
        XCTAssertFalse(MarkdownToNotionBlocks.hasFullTranscriptHeading(in: unicodeBreak))
        XCTAssertFalse(MarkdownToNotionBlocks.convert(markdown: unicodeBreak, transcript: nil).contains { $0.type == "toggle" })
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

    // MARK: - Single oversized blocks

    /// Walks an encoded request the way Notion's validation does and reports every documented limit it breaks.
    /// Independent of the production check on purpose, so the two cannot agree by sharing a mistake.
    private func limitViolations(in value: Any, key: String? = nil) -> [String] {
        var found: [String] = []
        if let array = value as? [Any] {
            if key == "rich_text" || key == "children", array.count > 100 { found.append("\(key ?? "") has \(array.count) elements") }
            if key == "cells" {
                for cell in array {
                    if let items = cell as? [Any], items.count > 100 { found.append("cell has \(items.count) rich text elements") }
                }
            }
            for item in array {
                found += limitViolations(in: item)
            }
        } else if let object = value as? [String: Any] {
            for (name, child) in object {
                if name == "content", let text = child as? String, text.utf16.count > 2000 {
                    found.append("text of \(text.utf16.count) UTF-16 units")
                }
                found += limitViolations(in: child, key: name)
            }
        }
        return found
    }

    private func nestedChildCount(in value: Any) -> Int {
        if let array = value as? [Any] { return array.reduce(0) { $0 + nestedChildCount(in: $1) } }
        guard let object = value as? [String: Any] else { return 0 }
        return object.reduce(0) { total, entry in
            total + (entry.key == "children" ? (entry.value as? [Any])?.count ?? 0 : 0) + nestedChildCount(in: entry.value)
        }
    }

    /// Splits like the client does, then checks every request against Notion's documented limits.
    private func assertRequestsWithinLimits(_ blocks: [NotionBlock], file: StaticString = #filePath, line: UInt = #line) throws {
        let batches = try NotionRequestBatches.split(blocks)
        XCTAssertEqual(batches.flatMap(\.self).count, blocks.count, file: file, line: line)
        for batch in batches {
            let data = try JSONEncoder().encode(NotionBlockAppendRequest(children: batch))
            XCTAssertLessThanOrEqual(batch.count, 100, file: file, line: line)
            XCTAssertLessThanOrEqual(data.count, 500_000, file: file, line: line)
            let json = try JSONSerialization.jsonObject(with: data)
            XCTAssertLessThanOrEqual(batch.count + nestedChildCount(in: json), 1000, file: file, line: line)
            XCTAssertEqual(limitViolations(in: json), [], file: file, line: line)
        }
    }

    private func plainText(of blocks: [NotionBlock]) throws -> String {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(blocks))
        func collect(_ value: Any) -> String {
            if let array = value as? [Any] { return array.map(collect).joined() }
            guard let object = value as? [String: Any] else { return "" }
            if let text = object["content"] as? String { return text }
            return object.keys.sorted().map { collect(object[$0] as Any) }.joined()
        }
        return collect(json)
    }

    private func chunkTexts(of richText: [[String: AnyEncodable]]) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(richText))
        let items = try XCTUnwrap(json as? [[String: Any]])
        return try items.map { try XCTUnwrap(($0["text"] as? [String: Any])?["content"] as? String) }
    }

    func testToggleOfVeryLongSpeakerLinesIsSplitIntoSeveralToggles() throws {
        let lines = (0 ..< 8).map { "[Speaker \($0)]: " + String(repeating: "x", count: 190_000) }
        let blocks = MarkdownToNotionBlocks.convert(markdown: "# Title", transcript: lines.joined(separator: "\n"))

        XCTAssertGreaterThan(blocks.filter { $0.type == "toggle" }.count, 1)
        try assertRequestsWithinLimits(blocks)
        let transcriptText = try plainText(of: blocks.filter { $0.type == "toggle" })
        XCTAssertEqual(transcriptText.count { $0 == "x" }, 8 * 190_000, "no transcript text may be dropped")
    }

    func testOneMonologueLineBeyondOneParagraphIsSplitAcrossParagraphs() throws {
        let monologue = String(repeating: "word ", count: 120_000)
        let blocks = MarkdownToNotionBlocks.convert(markdown: "# Title", transcript: monologue)

        try assertRequestsWithinLimits(blocks)
        let transcriptText = try plainText(of: blocks.filter { $0.type == "toggle" })
        XCTAssertEqual(transcriptText.count { $0 == "w" }, 120_000)
    }

    func testParagraphWithMoreThanOneHundredSpansStaysInsideTheRichTextLimit() throws {
        let line = (0 ..< 150).map { "**bold \($0)** plain" }.joined(separator: " ")
        let blocks = MarkdownToNotionBlocks.convert(markdown: line)

        XCTAssertEqual(blocks.map(\.type), ["paragraph"])
        try assertRequestsWithinLimits(blocks)
        XCTAssertTrue(try plainText(of: blocks).contains("bold 149"), "the text of the last span must survive")
    }

    func testParagraphWithinOneHundredSpansKeepsItsFormatting() {
        let line = (0 ..< 40).map { "**b\($0)** p" }.joined(separator: " ")
        let richText = MarkdownToNotionBlocks.makeRichText(line)
        XCTAssertLessThanOrEqual(richText.count, 100)
        XCTAssertGreaterThan(richText.count, 40)
        XCTAssertTrue(richText.contains { $0["annotations"] != nil })
    }

    func testEmojiHeavyLineIsCountedInUTF16Units() throws {
        // A family emoji is one Character but 11 UTF-16 units: 600 of them are 6600 units.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let line = String(repeating: family, count: 600)
        XCTAssertLessThan(line.count, 2000)
        XCTAssertGreaterThan(line.utf16.count, 2000)

        let chunks = try chunkTexts(of: MarkdownToNotionBlocks.makeRichText(line))
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 2000 })
        XCTAssertEqual(chunks.joined(), line, "chunks must cut between emoji, never inside one")
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count.isMultiple(of: family.utf16.count) }, "every chunk holds whole emoji")

        try assertRequestsWithinLimits(MarkdownToNotionBlocks.convert(markdown: line, transcript: line))
    }

    func testSingleGraphemeBeyondTheTextLimitIsStillSplit() throws {
        let stacked = "e" + String(repeating: "\u{0301}", count: 3000)
        XCTAssertEqual(stacked.count, 1)
        let chunks = try chunkTexts(of: MarkdownToNotionBlocks.makeRichText(stacked))
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 2000 })
        XCTAssertEqual(chunks.joined(), stacked)
    }

    func testProtocolParagraphBeyondOneBlocksRichTextRoomIsSplitIntoSeveralParagraphs() throws {
        let long = String(repeating: "y", count: 450_000)
        let blocks = MarkdownToNotionBlocks.convert(markdown: "## Notes\n\(long)")

        XCTAssertGreaterThan(blocks.count, 2)
        XCTAssertEqual(blocks.dropFirst().map(\.type), Array(repeating: "paragraph", count: blocks.count - 1))
        try assertRequestsWithinLimits(blocks)
        XCTAssertEqual(try plainText(of: blocks).count { $0 == "y" }, 450_000)
    }

    func testTableCellBeyondTheRichTextLimitFallsBackToText() throws {
        let cell = (0 ..< 150).map { "*i\($0)* x" }.joined(separator: " ")
        let blocks = MarkdownToNotionBlocks.convert(markdown: "| h |\n| --- |\n| \(cell) |")
        try assertRequestsWithinLimits(blocks)
        XCTAssertTrue(try plainText(of: blocks).contains("i149"))
    }

    func testTableTooLargeToSendFallsBackToText() throws {
        let cell = String(repeating: "c", count: 1900)
        let rows = (0 ..< 60).map { _ in "| \(cell) | \(cell) | \(cell) |" }.joined(separator: "\n")
        let blocks = MarkdownToNotionBlocks.convert(markdown: "| x | y | z |\n| --- | --- | --- |\n\(rows)")

        XCTAssertFalse(blocks.contains { $0.type == "table" })
        try assertRequestsWithinLimits(blocks)
        XCTAssertEqual(try plainText(of: blocks).count { $0 == "c" }, 60 * 3 * 1900)
    }

    func testBlockThatCannotBeMadeToFitFailsWithASpecificError() throws {
        let rich = Array(repeating: MarkdownToNotionBlocks.makeRichText("a")[0], count: 101)
        let block = NotionBlock(type: "paragraph", content: ["rich_text": AnyEncodable(rich)])

        XCTAssertThrowsError(try NotionRequestBatches.split([block])) { error in
            XCTAssertEqual(error as? NotionBlockTooLargeError, NotionBlockTooLargeError())
            XCTAssertEqual(NotionClientError.exportFailureReason(for: error), "a block is too large for Notion")
        }
    }

    func testOversizedToggleChildrenFailWithASpecificError() throws {
        let child = NotionBlock(type: "paragraph", content: ["rich_text": AnyEncodable(MarkdownToNotionBlocks.makeRichText("a"))])
        let toggle = NotionBlock(
            type: "toggle",
            content: [
                "rich_text": AnyEncodable(MarkdownToNotionBlocks.makeRichText("t")),
                "children": AnyEncodable(Array(repeating: child, count: 101)),
            ],
        )
        XCTAssertThrowsError(try NotionRequestBatches.split([toggle])) { XCTAssertTrue($0 is NotionBlockTooLargeError) }
    }

    func testTextBeyondTheCharacterLimitInABlockFailsWithASpecificError() throws {
        let item: [String: AnyEncodable] = [
            "type": AnyEncodable("text"),
            "text": AnyEncodable(["content": AnyEncodable(String(repeating: "a", count: 2001))]),
        ]
        let block = NotionBlock(type: "paragraph", content: ["rich_text": AnyEncodable([item])])
        XCTAssertThrowsError(try NotionRequestBatches.split([block])) { XCTAssertTrue($0 is NotionBlockTooLargeError) }
    }
}
