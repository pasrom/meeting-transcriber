import Foundation
@testable import MeetingTranscriber
import XCTest

final class TerminologyNormalizerTests: XCTestCase {
    func testRulesReplaceOnlyWholeWordsAndPreserveCanonicalCasing() {
        let normalizer = TerminologyNormalizer(rulesText: "Aster => Astor | Asterx")

        XCTAssertEqual(
            normalizer.normalize("Astor met Asterx; Astoria bleibt unverändert."),
            "Aster met Aster; Astoria bleibt unverändert.",
        )
    }

    func testRulesSupportMultiWordVariantsCaseInsensitively() {
        let normalizer = TerminologyNormalizer(rulesText: "Northstar Suite => north star suite")

        XCTAssertEqual(normalizer.normalize("Die NORTH STAR SUITE startet."), "Die Northstar Suite startet.")
    }

    func testMalformedAndEmptyRulesDoNotModifyText() {
        let normalizer = TerminologyNormalizer(rulesText: "missing delimiter\n=> empty\nTarget =>")

        XCTAssertTrue(normalizer.isEmpty)
        XCTAssertEqual(normalizer.normalize("Astor"), "Astor")
    }

    func testRulesDoNotCascadeIntoLaterRules() {
        let normalizer = TerminologyNormalizer(rulesText: "Beta => Alpha\nGamma => Beta")

        XCTAssertEqual(normalizer.normalize("Alpha"), "Beta")
    }

    func testExpansionRuleLeavesAnAlreadyCanonicalPhraseUntouched() {
        let normalizer = TerminologyNormalizer(rulesText: "Kubernetes Cluster => Cluster")
        let canonical = "Der Kubernetes Cluster laeuft stabil."

        XCTAssertEqual(normalizer.normalize(canonical), canonical)
        XCTAssertEqual(normalizer.normalize(normalizer.normalize(canonical)), canonical)
        XCTAssertEqual(
            normalizer.normalize("Der Cluster laeuft stabil."),
            "Der Kubernetes Cluster laeuft stabil.",
        )
    }

    func testPrefixExpansionVariantContractsBeforeItsCanonicalPrefix() {
        let normalizer = TerminologyNormalizer(rulesText: "Kubernetes => Kubernetes Cluster")

        XCTAssertEqual(
            normalizer.normalize("Der Kubernetes Cluster laeuft stabil."),
            "Der Kubernetes laeuft stabil.",
        )
    }

    func testCasingOnlyRuleCanonicalizesCasing() {
        let normalizer = TerminologyNormalizer(rulesText: "Northstar => northstar")

        XCTAssertFalse(normalizer.isEmpty)
        XCTAssertEqual(normalizer.normalize("northstar plant."), "Northstar plant.")
    }

    func testDiagnosticsReportActiveAndMalformedRules() {
        let normalizer = TerminologyNormalizer(
            rulesText: "Northstar => north star\nnot a rule\nA => B => C",
        )

        XCTAssertEqual(normalizer.diagnostics.activeRuleCount, 1)
        XCTAssertEqual(normalizer.diagnostics.ignoredLineCount, 2)
    }

    func testRulesAboveTheByteLimitAreRejectedWithoutCompilingRegexes() {
        let normalizer = TerminologyNormalizer(
            rulesText: String(repeating: "x", count: TerminologyNormalizer.maximumRulesTextBytes + 1),
        )

        XCTAssertTrue(normalizer.isEmpty)
        XCTAssertTrue(normalizer.diagnostics.isTooLarge)
    }

    func testRuleLimitAccepts200Rules() {
        let validRules = (0 ..< 200)
            .map { "Canonical\($0) => variant\($0)" }
        let normalizer = TerminologyNormalizer(rulesText: validRules.joined(separator: "\n"))

        XCTAssertEqual(normalizer.diagnostics.activeRuleCount, 200)
        XCTAssertEqual(normalizer.diagnostics.ignoredLineCount, 0)
    }

    func testRuleLimitReportsThe201stRuleAsIgnored() {
        let validRules = (0 ..< 200)
            .map { "Canonical\($0) => variant\($0)" }
        let normalizer = TerminologyNormalizer(rulesText: (validRules + ["Extra => extra"]).joined(separator: "\n"))

        XCTAssertEqual(normalizer.diagnostics.activeRuleCount, 200)
        XCTAssertEqual(normalizer.diagnostics.ignoredLineCount, 1)
    }

    func testCanonicalTermWith512BytesIsAccepted() {
        let canonical = String(repeating: "x", count: 512)
        let normalizer = TerminologyNormalizer(rulesText: "\(canonical) => alias")

        XCTAssertFalse(normalizer.isEmpty)
        XCTAssertEqual(normalizer.diagnostics.activeRuleCount, 1)
        XCTAssertEqual(normalizer.normalize("alias"), canonical)
    }

    func testCanonicalTermWith513BytesIsIgnored() {
        let canonical = String(repeating: "x", count: 513)
        let normalizer = TerminologyNormalizer(rulesText: "\(canonical) => alias")

        XCTAssertTrue(normalizer.isEmpty)
        XCTAssertEqual(normalizer.diagnostics.ignoredLineCount, 1)
    }

    func testVariantTermWith512BytesIsAccepted() {
        let variant = String(repeating: "x", count: 512)
        let normalizer = TerminologyNormalizer(rulesText: "Canonical => \(variant)")

        XCTAssertFalse(normalizer.isEmpty)
        XCTAssertEqual(normalizer.diagnostics.activeRuleCount, 1)
        XCTAssertEqual(normalizer.normalize(variant), "Canonical")
    }

    func testVariantTermWith513BytesIsIgnored() {
        let variant = String(repeating: "x", count: 513)
        let normalizer = TerminologyNormalizer(rulesText: "Canonical => \(variant)")

        XCTAssertTrue(normalizer.isEmpty)
        XCTAssertEqual(normalizer.diagnostics.ignoredLineCount, 1)
    }
}
