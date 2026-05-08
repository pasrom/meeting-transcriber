@testable import MeetingTranscriber
import XCTest

final class WERCalculatorTests: XCTestCase {
    // MARK: - Identity & empty cases

    func test_identicalStrings_returnsZero() {
        XCTAssertEqual(WERCalculator.wer(reference: "hello world", hypothesis: "hello world"), 0.0)
    }

    func test_bothEmpty_returnsZero() {
        XCTAssertEqual(WERCalculator.wer(reference: "", hypothesis: ""), 0.0)
    }

    func test_emptyReference_emptyHypothesis_returnsZero() {
        XCTAssertEqual(WERCalculator.wer(reference: "   ", hypothesis: ""), 0.0)
    }

    func test_emptyReference_nonEmptyHypothesis_returnsOne() {
        // Convention: pure insertions when reference is empty score WER = 1.0
        // (else division-by-zero). Documented in WERCalculator.
        XCTAssertEqual(WERCalculator.wer(reference: "", hypothesis: "spurious words"), 1.0)
    }

    // MARK: - Substitution / Deletion / Insertion

    func test_oneSubstitution_inFiveWords_returnsZeroPointTwo() {
        let wer = WERCalculator.wer(
            reference: "the quick brown fox jumps",
            hypothesis: "the quick red fox jumps",
        )
        XCTAssertEqual(wer, 0.2, accuracy: 1e-9)
    }

    func test_oneDeletion_inFiveWords_returnsZeroPointTwo() {
        let wer = WERCalculator.wer(
            reference: "the quick brown fox jumps",
            hypothesis: "the quick fox jumps",
        )
        XCTAssertEqual(wer, 0.2, accuracy: 1e-9)
    }

    func test_oneInsertion_inFiveWords_returnsZeroPointTwo() {
        let wer = WERCalculator.wer(
            reference: "the quick brown fox jumps",
            hypothesis: "the quick brown lazy fox jumps",
        )
        XCTAssertEqual(wer, 0.2, accuracy: 1e-9)
    }

    func test_completelyDifferent_returnsOne() {
        let wer = WERCalculator.wer(
            reference: "alpha beta gamma",
            hypothesis: "delta epsilon zeta",
        )
        XCTAssertEqual(wer, 1.0, accuracy: 1e-9)
    }

    // MARK: - Normalization

    func test_caseDifferences_areIgnored() {
        XCTAssertEqual(
            WERCalculator.wer(reference: "Hello World", hypothesis: "hello world"),
            0.0,
        )
    }

    func test_punctuationIsStripped() {
        XCTAssertEqual(
            WERCalculator.wer(reference: "Hello, world!", hypothesis: "hello world"),
            0.0,
        )
    }

    func test_collapsesWhitespace() {
        XCTAssertEqual(
            WERCalculator.wer(reference: "hello   world", hypothesis: "hello\tworld\n"),
            0.0,
        )
    }

    func test_germanUmlautsPreserved() {
        // ä/ö/ü/ß must NOT be folded to a/o/u/ss — Bundeskanzler vs Bundeskänzler
        // is a substitution, not equality.
        let wer = WERCalculator.wer(reference: "schön", hypothesis: "schon")
        XCTAssertEqual(wer, 1.0, accuracy: 1e-9)
    }

    func test_germanCompoundWord_documentedAsSubstitutionPlusInsertion() {
        // "Bundeskanzler" (1 word) → "Bundes Kanzler" (2 words):
        //   ref=[Bundeskanzler], hyp=[Bundes, Kanzler]
        //   1 substitution (Bundeskanzler → Bundes) + 1 insertion (Kanzler) = 2 errors
        //   2 / 1 = 2.0 (capped at 1.0 by callers if needed; raw value here)
        // This is the documented norm strategy: no compound-splitting, raw WER.
        let wer = WERCalculator.wer(
            reference: "Bundeskanzler",
            hypothesis: "Bundes Kanzler",
        )
        XCTAssertEqual(wer, 2.0, accuracy: 1e-9)
    }

    // MARK: - Counts breakdown (for diagnostic output)

    //
    // Each case is constructed so the optimal alignment is unique — otherwise
    // the algorithm could pick a different (but equally optimal) decomposition
    // and the assertions would flake.

    func test_breakdown_pureSubstitution() {
        // ref: "alpha bravo charlie"  hyp: "alpha XXX charlie"
        let result = WERCalculator.werBreakdown(
            reference: "alpha bravo charlie",
            hypothesis: "alpha xxx charlie",
        )
        XCTAssertEqual(result.substitutions, 1)
        XCTAssertEqual(result.deletions, 0)
        XCTAssertEqual(result.insertions, 0)
        XCTAssertEqual(result.referenceLength, 3)
        XCTAssertEqual(result.wer, 1.0 / 3.0, accuracy: 1e-9)
    }

    func test_breakdown_pureDeletion() {
        // ref: "alpha bravo charlie"  hyp: "alpha charlie" — bravo deleted
        let result = WERCalculator.werBreakdown(
            reference: "alpha bravo charlie",
            hypothesis: "alpha charlie",
        )
        XCTAssertEqual(result.substitutions, 0)
        XCTAssertEqual(result.deletions, 1)
        XCTAssertEqual(result.insertions, 0)
        XCTAssertEqual(result.referenceLength, 3)
        XCTAssertEqual(result.wer, 1.0 / 3.0, accuracy: 1e-9)
    }

    func test_breakdown_pureInsertion() {
        // ref: "alpha charlie"  hyp: "alpha bravo charlie" — bravo inserted
        let result = WERCalculator.werBreakdown(
            reference: "alpha charlie",
            hypothesis: "alpha bravo charlie",
        )
        XCTAssertEqual(result.substitutions, 0)
        XCTAssertEqual(result.deletions, 0)
        XCTAssertEqual(result.insertions, 1)
        XCTAssertEqual(result.referenceLength, 2)
        XCTAssertEqual(result.wer, 1.0 / 2.0, accuracy: 1e-9)
    }
}
