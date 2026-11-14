@testable import MeetingTranscriber
import XCTest

/// The AI meeting title in a protocol heading and the file name slug built from it.
final class ProtocolGeneratorTitleTests: XCTestCase {
    // MARK: - Snake Case

    func testToSnakeCaseStandardTitle() {
        XCTAssertEqual(ProtocolGenerator.toSnakeCase("Sprint Planning 24"), "sprint_planning_24")
    }

    func testToSnakeCaseHyphensAndPunctuation() {
        XCTAssertEqual(
            ProtocolGenerator.toSnakeCase("Sprint 24: Planning & Review (Q3)"),
            "sprint_24_planning_review_q3",
        )
    }

    func testToSnakeCaseMultipleSpacesAndDashes() {
        XCTAssertEqual(
            ProtocolGenerator.toSnakeCase("   Architecture   --   Design   "),
            "architecture_design",
        )
    }

    /// A title with nothing to name a file after has no slug. The caller keeps
    /// the timestamped name instead of filing every such meeting as "meeting".
    func testToSnakeCaseReturnsNilWhenNothingAlphanumericRemains() {
        XCTAssertNil(ProtocolGenerator.toSnakeCase("///"))
        XCTAssertNil(ProtocolGenerator.toSnakeCase("   "))
        XCTAssertNil(ProtocolGenerator.toSnakeCase("🚀🎉"))
    }

    func testToSnakeCaseUnicodeAndDiacritics() {
        XCTAssertEqual(
            ProtocolGenerator.toSnakeCase("Pembahasan Anggaran 2026"),
            "pembahasan_anggaran_2026",
        )
        XCTAssertEqual(ProtocolGenerator.toSnakeCase("Größe Änderung"), "größe_änderung")
    }

    /// An LLM heading has no length bound, a file name component has one
    /// (255 bytes on APFS) and the longest artifact suffix plus a short id still
    /// has to fit after the slug.
    func testToSnakeCaseCapsTheSlugInBytesWithoutSplittingACharacter() throws {
        let umlauts = String(repeating: "ä", count: 400)
        let slug = try XCTUnwrap(ProtocolGenerator.toSnakeCase(umlauts))
        XCTAssertLessThanOrEqual(slug.utf8.count, ProtocolGenerator.maxSlugBytes)
        XCTAssertEqual(slug, String(repeating: "ä", count: slug.count), "cut on a character boundary")

        let words = try XCTUnwrap(ProtocolGenerator.toSnakeCase(
            String(repeating: "planning ", count: 60),
        ))
        XCTAssertLessThanOrEqual(words.utf8.count, ProtocolGenerator.maxSlugBytes)
        XCTAssertFalse(words.hasSuffix("_"), "a cut inside the separator must not leave a trailing underscore")
    }

    // MARK: - AI Title Extraction

    func testExtractTitleStandardHeading() {
        let md = """
        # Meeting Protocol - Sprint Planning
        **Date:** 2026-10-14
        ## Summary
        Meeting summary.
        """
        XCTAssertEqual(ProtocolGenerator.extractTitle(from: md), "Sprint Planning")
    }

    func testExtractTitleWithColonAfterAKnownPrefix() {
        let md = "# Meeting Protocol: Architecture Review\n**Date:** 2026-10-14"
        XCTAssertEqual(ProtocolGenerator.extractTitle(from: md), "Architecture Review")
    }

    func testExtractTitleWithEmDash() {
        let md = "# Meeting Protocol — Q3 Roadmap Sync\n**Date:** 2026-10-14"
        XCTAssertEqual(ProtocolGenerator.extractTitle(from: md), "Q3 Roadmap Sync")
    }

    func testExtractTitleWithEnDash() {
        let md = "# Meeting Protocol – Q3 Roadmap Sync\n**Date:** 2026-10-14"
        XCTAssertEqual(ProtocolGenerator.extractTitle(from: md), "Q3 Roadmap Sync")
    }

    func testExtractTitleDirectHeading() {
        let md = "# Product Architecture Discussion\n**Date:** 2026-10-14"
        XCTAssertEqual(ProtocolGenerator.extractTitle(from: md), "Product Architecture Discussion")
    }

    /// A colon inside a direct title is part of the title, not a prefix separator.
    func testExtractTitleKeepsAColonInsideADirectTitle() {
        XCTAssertEqual(
            ProtocolGenerator.extractTitle(from: "# Sprint 24: Planning"),
            "Sprint 24: Planning",
        )
        XCTAssertEqual(
            ProtocolGenerator.extractTitle(from: "# Sprint Review: Team Alpha - Q3"),
            "Sprint Review: Team Alpha - Q3",
        )
    }

    /// Only the first dash separates a prefix, so a dash inside the title survives.
    func testExtractTitleKeepsEverythingAfterTheFirstDash() {
        XCTAssertEqual(
            ProtocolGenerator.extractTitle(from: "# Meeting Protocol - Q3 Review - Budget"),
            "Q3 Review - Budget",
        )
    }

    /// A lead-in of more than three words is part of the title, not a protocol label.
    func testExtractTitleKeepsALongLeadInBeforeADash() {
        XCTAssertEqual(
            ProtocolGenerator.extractTitle(from: "# Quarterly Budget Review Meeting Notes - Q3"),
            "Quarterly Budget Review Meeting Notes - Q3",
        )
    }

    func testExtractTitleLocalized() {
        let indonesian = "# Protokol Rapat - Pembahasan Anggaran\n**Tanggal:** 2026-10-14"
        XCTAssertEqual(ProtocolGenerator.extractTitle(from: indonesian), "Pembahasan Anggaran")

        let german = "# Besprechungsprotokoll - Budgetplanung 2026\n**Datum:** 2026-10-14"
        XCTAssertEqual(ProtocolGenerator.extractTitle(from: german), "Budgetplanung 2026")
    }

    func testExtractTitleRejectsPlaceholders() {
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Meeting Protocol - [Meeting Title]"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Meeting Protocol - Meeting Title"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Meeting Protocol"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Protocol"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Besprechungsprotokoll - [Titel]"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Meeting Protocol - Untitled"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Meeting Protocol - TBD"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Besprechungsprotokoll - Titel der Besprechung"))
        // The label with an empty title slot, with every dash the prompt may use.
        for dash in ["-", "–", "—", ":"] {
            XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Meeting Protocol \(dash)"), dash)
        }
    }

    /// The model translates the template's `[Meeting Title]` into the protocol
    /// language, so a fixed word list cannot cover it. A title still wrapped in
    /// square brackets is the unfilled template, whatever language it is in.
    func testExtractTitleRejectsABracketedTitleInAnyLanguage() {
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Besprechungsprotokoll - [Titel der Besprechung]"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Compte rendu de réunion - [Titre de la réunion]"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# 会議議事録 - [会議タイトル]"))
        XCTAssertNil(ProtocolGenerator.extractTitle(from: "# Meeting Protocol - [Sprint Planning 24]"))
    }

    func testExtractTitleStripsMarkdownEmphasisAndQuotes() {
        XCTAssertEqual(ProtocolGenerator.extractTitle(from: "# Meeting Protocol - **\"Budget Review\"**"), "Budget Review")
    }

    func testExtractTitleNoHeadingReturnsNil() {
        let text = "Just plain text without any markdown headings."
        XCTAssertNil(ProtocolGenerator.extractTitle(from: text))
    }

    /// Notes from a template that writes only section headings have no title:
    /// a `## ` heading is a section, never the meeting's name.
    func testExtractTitleIgnoresSectionHeadings() {
        let notes = """
        ## Action items
        - Alice sends the budget

        ### Decisions
        Ship on Friday.
        """
        XCTAssertNil(ProtocolGenerator.extractTitle(from: notes))
    }

    // MARK: - The title against the template the notes came from

    /// Only the built-in template asks for a `# <label> - <title>` heading; a
    /// custom template's first heading is a section as often as a title.
    func testAITitleIsTakenOnlyFromNotesOfTheBuiltInTemplate() {
        let notes = "# Meeting Protocol - Sprint Planning\n\n## Decisions\n"

        XCTAssertEqual(ProtocolGenerator.aiTitle(from: notes, template: .builtIn), "Sprint Planning")
        XCTAssertNil(ProtocolGenerator.aiTitle(from: "# Action items\n", template: .file(name: "Board")))
        XCTAssertNil(ProtocolGenerator.aiTitle(from: notes, template: .file(name: "Board")))
    }

    func testFileTitleSlugNeedsTheSettingAndTheBuiltInTemplate() {
        let notes = "# Meeting Protocol - Sprint Planning\n"

        XCTAssertEqual(ProtocolGenerator.fileTitleSlug(from: notes, enabled: true, template: .builtIn), "sprint_planning")
        XCTAssertNil(ProtocolGenerator.fileTitleSlug(from: notes, enabled: false, template: .builtIn))
        XCTAssertNil(ProtocolGenerator.fileTitleSlug(from: notes, enabled: true, template: .file(name: "Board")))
    }
}
