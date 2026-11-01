import Foundation

/// Converts markdown strings into Notion block structures for API export.
enum MarkdownToNotionBlocks {
    /// Notion's limit for one rich text item, counted here in UTF-16 units.
    private static let maxTextLength = NotionRequestBatches.maxTextUnits
    private static let maxRichTextElements = NotionRequestBatches.maxArrayCount
    private static let maxChildrenPerBlock = 95
    /// Size of one transcript paragraph and of one transcript toggle once encoded. A toggle
    /// stays well under `NotionRequestBatches.maxBytes`, so it always fits a request alone.
    private static let maxParagraphBytes = 200_000
    private static let maxToggleBytes = 380_000

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
                    blocks.append(contentsOf: tableLines.flatMap { makeTextBlocks(type: "paragraph", text: $0) })
                }
                continue
            }

            // Headings
            if trimmed.hasPrefix("### ") {
                let content = String(trimmed.dropFirst(4))
                blocks.append(contentsOf: makeTextBlocks(type: "heading_3", text: content))
            } else if trimmed.hasPrefix("## ") {
                let content = String(trimmed.dropFirst(3))
                blocks.append(contentsOf: makeTextBlocks(type: "heading_2", text: content))
            } else if trimmed.hasPrefix("# ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(contentsOf: makeTextBlocks(type: "heading_1", text: content))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(makeDivider())
            } else if trimmed.hasPrefix("> ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(contentsOf: makeTextBlocks(type: "quote", text: content))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(contentsOf: makeTextBlocks(type: "bulleted_list_item", text: content))
            } else if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let content = String(trimmed[match.upperBound...])
                blocks.append(contentsOf: makeTextBlocks(type: "numbered_list_item", text: content))
            } else {
                blocks.append(contentsOf: makeTextBlocks(type: "paragraph", text: trimmed))
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

    private static func makeDivider() -> NotionBlock {
        NotionBlock(type: "divider", content: [:])
    }

    /// One block of `type` for the text, or several in a row when its rich text runs past
    /// Notion's per-array limit (text beyond about 200,000 UTF-16 units): a heading or list
    /// item then repeats rather than the export failing on every retry.
    private static func makeTextBlocks(type: String, text: String) -> [NotionBlock] {
        let richText = makeRichText(text)
        return stride(from: 0, to: richText.count, by: maxRichTextElements).map { start in
            let slice = Array(richText[start ..< min(start + maxRichTextElements, richText.count)])
            return NotionBlock(type: type, content: ["rich_text": AnyEncodable(slice)])
        }
    }

    private static let maxTableRows = NotionRequestBatches.maxArrayCount

    private static func makeTranscriptToggles(from transcript: String) -> [NotionBlock] {
        let lines = transcript.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        // Chunk lines into paragraph blocks of ~1200 characters each
        var chunkTexts: [String] = []
        var currentChunk = ""

        for line in lines {
            if !currentChunk.isEmpty, currentChunk.count + line.count + 1 > 1200 {
                chunkTexts.append(currentChunk)
                currentChunk = line
            } else if currentChunk.isEmpty {
                currentChunk = line
            } else {
                currentChunk += "\n" + line
            }
        }
        if !currentChunk.isEmpty {
            chunkTexts.append(currentChunk)
        }
        let paragraphs = chunkTexts.flatMap { makePlainParagraphs(text: $0) }

        // Split into toggles capped at maxChildrenPerBlock children and at maxToggleBytes
        // once encoded, so a few very long speaker lines cannot make one toggle too big to send.
        var toggles: [NotionBlock] = []
        var slice: [NotionBlock] = []
        var sliceBytes = 0

        func closeToggle() {
            guard !slice.isEmpty else { return }
            let title = toggles.isEmpty ? "Full Transcript" : "Full Transcript (Part \(toggles.count + 1))"
            toggles.append(NotionBlock(
                type: "toggle",
                content: [
                    "rich_text": AnyEncodable(makeRichText(title)),
                    "children": AnyEncodable(slice),
                ],
            ))
            slice = []
            sliceBytes = 0
        }

        for (paragraph, bytes) in paragraphs {
            if slice.count >= maxChildrenPerBlock || sliceBytes + bytes > maxToggleBytes { closeToggle() }
            slice.append(paragraph)
            sliceBytes += bytes
        }
        closeToggle()

        return toggles
    }

    /// The text as one plain paragraph with its encoded size, or as several when one would
    /// exceed Notion's rich text array limit or `maxParagraphBytes`: a monologue longer than
    /// roughly 200,000 characters, or text whose escaping makes it unusually large to send.
    private static func makePlainParagraphs(text: String) -> [(block: NotionBlock, bytes: Int)] {
        let richText = makeRichTextChunks(text)
        let block = NotionBlock(type: "paragraph", content: ["rich_text": AnyEncodable(richText)])
        let bytes = (try? JSONEncoder().encode(block).count) ?? 0
        guard richText.count > maxRichTextElements || bytes > maxParagraphBytes, text.count > 1 else {
            return [(block, bytes)]
        }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        return makePlainParagraphs(text: String(text[..<middle])) + makePlainParagraphs(text: String(text[middle...]))
    }

    // MARK: - Table Parsing

    /// A cell is one rich text array, which cannot be split across blocks.
    private static func cellsFit(_ cells: [[[String: AnyEncodable]]]) -> Bool {
        cells.allSatisfy { $0.count <= maxRichTextElements }
    }

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
        guard cellsFit(headerRowCells) else { return nil }
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
            guard cellsFit(richCells) else { return nil }
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
    ///
    /// Notion takes at most 100 rich text items per array. Text with more styled spans than
    /// that is sent as plain text with its markers left in place, so no text is lost; only
    /// text beyond roughly 200,000 UTF-16 units still exceeds the array, and callers split
    /// the block for that.
    static func makeRichText(_ text: String) -> [[String: AnyEncodable]] {
        let styled = makeStyledRichText(text)
        guard styled.count > maxRichTextElements else { return styled }
        return makeRichTextChunks(text)
    }

    private static func makeStyledRichText(_ text: String) -> [[String: AnyEncodable]] {
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

        return utf16Chunks(content, limit: maxTextLength).map { chunk in
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

    /// Cuts the text into pieces of at most `limit` UTF-16 units, between characters wherever
    /// it can: Notion may count in UTF-16 units, where one emoji is up to 11. A character
    /// longer than the limit by itself (a base with thousands of combining marks) is cut
    /// between its scalars instead.
    private static func utf16Chunks(_ content: String, limit: Int) -> [String] {
        guard content.utf16.count > limit else { return [content] }
        var chunks: [String] = []
        var current = ""
        var currentUnits = 0
        func add(_ piece: String) {
            let units = piece.utf16.count
            if currentUnits + units > limit {
                chunks.append(current)
                current = ""
                currentUnits = 0
            }
            current += piece
            currentUnits += units
        }
        for character in content {
            if character.utf16.count <= limit {
                add(String(character))
            } else {
                for scalar in character.unicodeScalars {
                    add(String(scalar))
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func makeEmptyRichText() -> [String: AnyEncodable] {
        [
            "type": AnyEncodable("text"),
            "text": AnyEncodable(["content": AnyEncodable("")]),
        ]
    }
}
