@testable import MeetingTranscriber
import XCTest

final class DERCalculatorTests: XCTestCase {
    // MARK: - Identity

    func test_identicalTimelines_returnsZero() {
        let ref: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 5),
            .init(speaker: "B", start: 5, end: 10),
        ]
        let der = DERCalculator.der(reference: ref, hypothesis: ref)
        XCTAssertEqual(der, 0.0, accuracy: 1e-9)
    }

    func test_speakerLabelsPermuted_returnsZeroAfterOptimalMapping() {
        // Same timeline, different labels — Hungarian/optimal-mapping should
        // recover DER = 0 by mapping hyp X → ref A, hyp Y → ref B.
        let ref: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 5),
            .init(speaker: "B", start: 5, end: 10),
        ]
        let hyp: [DERCalculator.Turn] = [
            .init(speaker: "X", start: 0, end: 5),
            .init(speaker: "Y", start: 5, end: 10),
        ]
        XCTAssertEqual(DERCalculator.der(reference: ref, hypothesis: hyp), 0.0, accuracy: 1e-9)
    }

    // MARK: - Single-error categories

    func test_missedSpeech_referenceLongerThanHypothesis() {
        // Reference: 0–10s speech (Speaker A). Hypothesis: 0–5s only.
        // Missed = 5s, total ref speech = 10s → DER = 0.5.
        let ref: [DERCalculator.Turn] = [.init(speaker: "A", start: 0, end: 10)]
        let hyp: [DERCalculator.Turn] = [.init(speaker: "A", start: 0, end: 5)]
        XCTAssertEqual(DERCalculator.der(reference: ref, hypothesis: hyp), 0.5, accuracy: 1e-9)
    }

    func test_falseAlarm_hypothesisLongerThanReference() {
        // Reference: 0–5s (Speaker A). Hypothesis: 0–10s (Speaker A).
        // False alarm = 5s, total ref speech = 5s → DER = 1.0.
        let ref: [DERCalculator.Turn] = [.init(speaker: "A", start: 0, end: 5)]
        let hyp: [DERCalculator.Turn] = [.init(speaker: "A", start: 0, end: 10)]
        XCTAssertEqual(DERCalculator.der(reference: ref, hypothesis: hyp), 1.0, accuracy: 1e-9)
    }

    func test_speakerConfusion_swapInMiddle() {
        // Reference: A 0–10. Hypothesis: A 0–6, B 6–10.
        // Best mapping is hyp-A→ref-A. Hyp B is confusion for 4s.
        // DER = 4 / 10 = 0.4.
        let ref: [DERCalculator.Turn] = [.init(speaker: "A", start: 0, end: 10)]
        let hyp: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 6),
            .init(speaker: "B", start: 6, end: 10),
        ]
        XCTAssertEqual(DERCalculator.der(reference: ref, hypothesis: hyp), 0.4, accuracy: 1e-9)
    }

    // MARK: - Edge cases

    func test_emptyHypothesis_allMissed_returnsOne() {
        let ref: [DERCalculator.Turn] = [.init(speaker: "A", start: 0, end: 10)]
        XCTAssertEqual(DERCalculator.der(reference: ref, hypothesis: []), 1.0, accuracy: 1e-9)
    }

    func test_emptyReference_emptyHypothesis_returnsZero() {
        XCTAssertEqual(DERCalculator.der(reference: [], hypothesis: []), 0.0, accuracy: 1e-9)
    }

    func test_emptyReference_nonEmptyHypothesis_returnsOne() {
        // No reference speech → divide-by-zero. Convention: return 1.0 to flag
        // the result as catastrophic without producing inf.
        let hyp: [DERCalculator.Turn] = [.init(speaker: "A", start: 0, end: 5)]
        XCTAssertEqual(DERCalculator.der(reference: [], hypothesis: hyp), 1.0, accuracy: 1e-9)
    }

    // MARK: - Breakdown

    func test_breakdown_reportsMissedFalseAlarmConfusion() {
        // Reference: A 0–5, B 5–10  (total ref = 10s)
        // Hypothesis: X 0–4, Y 4–8
        //
        // Overlaps: X·A=4, X·B=0, Y·A=1, Y·B=3 → best mapping X→A, Y→B
        //
        // Walk boundaries [0,4,5,8,10]:
        //   0–4: ref=A, hyp=X→A   → correct  (4s)
        //   4–5: ref=A, hyp=Y→B   → confusion (1s)
        //   5–8: ref=B, hyp=Y→B   → correct  (3s)
        //   8–10: ref=B, hyp=nil  → missed   (2s)
        //
        // missed=2, false_alarm=0, confusion=1, total_ref=10 → DER = 3/10 = 0.3
        let ref: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 5),
            .init(speaker: "B", start: 5, end: 10),
        ]
        let hyp: [DERCalculator.Turn] = [
            .init(speaker: "X", start: 0, end: 4),
            .init(speaker: "Y", start: 4, end: 8),
        ]
        let result = DERCalculator.derBreakdown(reference: ref, hypothesis: hyp)
        XCTAssertEqual(result.missedSpeech, 2.0, accuracy: 1e-9)
        XCTAssertEqual(result.falseAlarm, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.speakerConfusion, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.totalReference, 10.0, accuracy: 1e-9)
        XCTAssertEqual(result.der, 0.3, accuracy: 1e-9)
    }
}
