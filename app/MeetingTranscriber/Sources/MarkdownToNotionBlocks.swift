import Foundation

/// Converts markdown strings into Notion block structures for API export.
enum MarkdownToNotionBlocks {
    private static let maxTextLength = 2000
    private static let maxChildrenPerBlock = 95

    /// Converts markdown text (and optional verbatim transcript) into an array of `NotionBlock`s.
    static func convert(markdown: String, transcript: String? = nil) -> [NotionBlock] { // swiftlint:disable:this cyclomatic_complexity function_body_length
        var blocks: [NotionBlock] = []
        let rawLines = markdown.components(separatedBy: "\r\n")
            .flatMap { $0.components(separatedBy: "\n") }

        var lineIndex = 0
        var insideFullTranscript = false
        var transcriptLines: [String] = []

        while lineIndex < rawLines.count {
            let line = rawLines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                lineIndex += 1
                continue
            }

            // Check if this line starts a "Full Transcript" heading
            if trimmed.lowercased().hasPrefix("## full transcript") || trimmed.lowercased().hasPrefix("# full transcript") {
                insideFullTranscript = true
                lineIndex += 1
                continue
            }

            if insideFullTranscript {
                transcriptLines.append(trimmed)
                lineIndex += 1
                continue
            }

            // Check for Markdown table
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                var tableLines: [String] = []
                while lineIndex < rawLines.count {
                    let candidate = rawLines[lineIndex].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix("|") && candidate.hasSuffix("|") {
                        tableLines.append(candidate)
                        lineIndex += 1
                    } else {
                        break
                    }
                }
                if let tableBlock = parseTable(tableLines) {
                    blocks.append(tableBlock)
                } else {
                    blocks.append(contentsOf: tableLines.map { makeParagraph(text: $0) })
                }
                continue
            }

            // Headings
            if trimmed.hasPrefix("### ") {
                let content = String(trimmed.dropFirst(4))
                blocks.append(makeHeading(level: 3, text: content))
            } else if trimmed.hasPrefix("## ") {
                let content = String(trimmed.dropFirst(3))
                blocks.append(makeHeading(level: 2, text: content))
            } else if trimmed.hasPrefix("# ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(makeHeading(level: 1, text: content))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(makeDivider())
            } else if trimmed.hasPrefix("> ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(makeQuote(text: content))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(makeListItem(type: "bulleted_list_item", text: content))
            } else if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let content = String(trimmed[match.upperBound...])
                blocks.append(makeListItem(type: "numbered_list_item", text: content))
            } else {
                blocks.append(makeParagraph(text: trimmed))
            }

            lineIndex += 1
        }

        // Add explicit transcript or parsed transcript as collapsible toggle
        let finalTranscriptText: String? = {
            if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return transcript
            }
            if !transcriptLines.isEmpty {
                return transcriptLines.joined(separator: "\n\n")
            }
            return nil
        }()

        if let finalTranscriptText {
            // Without it the toggle reads as part of the section above. A saved
            // protocol re-exported on retry already carries its own divider.
            if blocks.last?.type != "divider" { blocks.append(makeDivider()) }
            blocks.append(contentsOf: makeTranscriptToggles(from: finalTranscriptText))
        }

        return blocks
    }

    // MARK: - Block Builders

    private static func makeHeading(level: Int, text: String) -> NotionBlock {
        let typeName = "heading_\(level)"
        return NotionBlock(
            type: typeName,
            content: ["rich_text": AnyEncodable(makeRichText(text))],
        )
    }

    private static func makeDivider() -> NotionBlock {
        NotionBlock(type: "divider", content: [:])
    }

    private static func makeQuote(text: String) -> NotionBlock {
        NotionBlock(
            type: "quote",
            content: ["rich_text": AnyEncodable(makeRichText(text))],
        )
    }

    private static func makeListItem(type: String, text: String) -> NotionBlock {
        NotionBlock(
            type: type,
            content: ["rich_text": AnyEncodable(makeRichText(text))],
        )
    }

    private static func makeParagraph(text: String) -> NotionBlock {
        NotionBlock(
            type: "paragraph",
            content: ["rich_text": AnyEncodable(makeRichText(text))],
        )
    }

    private static let maxTableRows = 100

    private static func makeTranscriptToggles(from transcript: String) -> [NotionBlock] {
        let lines = transcript.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        // Chunk lines into paragraph blocks of ~1200 characters each
        var paragraphBlocks: [NotionBlock] = []
        var currentChunk = ""

        for line in lines {
            if !currentChunk.isEmpty, currentChunk.count + line.count + 1 > 1200 {
                paragraphBlocks.append(makePlainParagraph(text: currentChunk))
                currentChunk = line
            } else if currentChunk.isEmpty {
                currentChunk = line
            } else {
                currentChunk += "\n" + line
            }
        }
        if !currentChunk.isEmpty {
            paragraphBlocks.append(makePlainParagraph(text: currentChunk))
        }

        // Split into toggles capped at maxChildrenPerBlock children
        var toggles: [NotionBlock] = []
        var chunkIndex = 0

        while chunkIndex < paragraphBlocks.count {
            let slice = Array(paragraphBlocks[chunkIndex ..< min(chunkIndex + maxChildrenPerBlock, paragraphBlocks.count)])
            let title = toggles.isEmpty ? "Full Transcript" : "Full Transcript (Part \(toggles.count + 1))"
            let toggleBlock = NotionBlock(
                type: "toggle",
                content: [
                    "rich_text": AnyEncodable(makeRichText(title)),
                    "children": AnyEncodable(slice),
                ],
            )
            toggles.append(toggleBlock)
            chunkIndex += maxChildrenPerBlock
        }

        return toggles
    }

    private static func makePlainParagraph(text: String) -> NotionBlock {
        NotionBlock(type: "paragraph", content: ["rich_text": AnyEncodable(makeRichTextChunks(text))])
    }

    // MARK: - Table Parsing

    private static func parseTable(_ lines: [String]) -> NotionBlock? {
        guard lines.count >= 2 else { return nil }

        func splitRow(_ line: String) -> [String] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") && trimmed.hasSuffix("|") else { return [] }
            let inner = trimmed.dropFirst().dropLast()
            return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let headerCells = splitRow(lines[0])
        guard !headerCells.isEmpty else { return nil }

        // Line 1 should be delimiter like |---|---|
        let delimiterCells = splitRow(lines[1])
        guard delimiterCells.count == headerCells.count,
              delimiterCells.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil })
        else { return nil }

        // Notion takes at most 100 children per block; a longer table stays readable as text.
        guard lines.count - 1 <= maxTableRows else { return nil }
        let width = headerCells.count
        var rowBlocks: [[String: AnyEncodable]] = []

        // Header row
        let headerRowCells = headerCells.map { cell in
            makeRichText(cell)
        }
        rowBlocks.append([
            "object": AnyEncodable("block"),
            "type": AnyEncodable("table_row"),
            "table_row": AnyEncodable(["cells": headerRowCells]),
        ])

        // Data rows
        for idx in 2 ..< lines.count {
            var cells = splitRow(lines[idx])
            while cells.count < width {
                cells.append("")
            }
            if cells.count > width {
                cells = Array(cells.prefix(width))
            }
            let richCells = cells.map { cell in
                makeRichText(cell)
            }
            rowBlocks.append([
                "object": AnyEncodable("block"),
                "type": AnyEncodable("table_row"),
                "table_row": AnyEncodable(["cells": richCells]),
            ])
        }

        return NotionBlock(
            type: "table",
            content: [
                "table_width": AnyEncodable(width),
                "has_column_header": AnyEncodable(true),
                "has_row_header": AnyEncodable(false),
                "children": AnyEncodable(rowBlocks),
            ],
        )
    }

    // MARK: - Rich Text Formatting

    /// Parses inline markdown styling (bold `**text**`, italic `*text*`, code `` `text` ``) into Notion rich text elements.
    ///
    /// Text longer than Notion's per-object limit is split into several rich
    /// text items. It used to be truncated, which silently dropped the tail of
    /// a long protocol paragraph or transcript line.
    static func makeRichText(_ text: String) -> [[String: AnyEncodable]] {
        guard !text.isEmpty else {
            return [makeEmptyRichText()]
        }

        let pattern = #"(\*\*([^\*]+)\*\*|\*([^\*]+)\*|`([^`]+)`)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return makeRichTextChunks(text)
        }

        var results: [[String: AnyEncodable]] = []
        // swiftlint:disable:next legacy_objc_type
        let nsString = text as NSString
        var lastLocation = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            let matchRange = match.range
            if matchRange.location > lastLocation {
                let leading = nsString.substring(with: NSRange(location: lastLocation, length: matchRange.location - lastLocation))
                results.append(contentsOf: makeRichTextChunks(leading))
            }

            let fullMatch = nsString.substring(with: matchRange)
            if fullMatch.hasPrefix("**") && fullMatch.hasSuffix("**") && fullMatch.count >= 4 {
                let inner = String(fullMatch.dropFirst(2).dropLast(2))
                results.append(contentsOf: makeRichTextChunks(inner, bold: true))
            } else if fullMatch.hasPrefix("*") && fullMatch.hasSuffix("*") && fullMatch.count >= 2 {
                let inner = String(fullMatch.dropFirst(1).dropLast(1))
                results.append(contentsOf: makeRichTextChunks(inner, italic: true))
            } else if fullMatch.hasPrefix("`") && fullMatch.hasSuffix("`") && fullMatch.count >= 2 {
                let inner = String(fullMatch.dropFirst(1).dropLast(1))
                results.append(contentsOf: makeRichTextChunks(inner, code: true))
            } else {
                results.append(contentsOf: makeRichTextChunks(fullMatch))
            }

            lastLocation = matchRange.location + matchRange.length
        }

        if lastLocation < nsString.length {
            let trailing = nsString.substring(with: NSRange(location: lastLocation, length: nsString.length - lastLocation))
            results.append(contentsOf: makeRichTextChunks(trailing))
        }

        return results.isEmpty ? [makeEmptyRichText()] : results
    }

    private static func makeRichTextChunks(
        _ content: String,
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false,
    ) -> [[String: AnyEncodable]] {
        guard !content.isEmpty else { return [] }

        var chunks: [String] = []
        var start = content.startIndex
        while start < content.endIndex {
            let end = content.index(start, offsetBy: maxTextLength, limitedBy: content.endIndex) ?? content.endIndex
            chunks.append(String(content[start ..< end]))
            start = end
        }

        return chunks.map { chunk in
            var object: [String: AnyEncodable] = [
                "type": AnyEncodable("text"),
                "text": AnyEncodable(["content": AnyEncodable(chunk)]),
            ]
            if bold || italic || code {
                object["annotations"] = AnyEncodable([
                    "bold": AnyEncodable(bold),
                    "italic": AnyEncodable(italic),
                    "code": AnyEncodable(code),
                ])
            }
            return object
        }
    }

    private static func makeEmptyRichText() -> [String: AnyEncodable] {
        [
            "type": AnyEncodable("text"),
            "text": AnyEncodable(["content": AnyEncodable("")]),
        ]
    }
}
