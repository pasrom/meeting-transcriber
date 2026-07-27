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

    // MARK: - Overlapping speech

    // Real meetings run roughly a third overlapping. These pin the behaviour
    // that a single-speaker-per-instant metric cannot express at all.
    func test_overlap_countsTowardTheDenominatorTwice() {
        // A talks 0-10, B talks 4-8 on top. Wall-clock speech is 10s but
        // reference SPEAKER-time is 14s, and a metric that says 10 charges
        // every error against a denominator ~30 % too small.
        let ref: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 10),
            .init(speaker: "B", start: 4, end: 8),
        ]
        let result = DERCalculator.derBreakdown(reference: ref, hypothesis: ref)
        XCTAssertEqual(result.totalReference, 14.0, accuracy: 1e-9)
        XCTAssertEqual(result.der, 0.0, accuracy: 1e-9)
    }

    func test_overlap_reportingOnlyOneOfTwoSimultaneousSpeakers_isMissedSpeech() {
        // The failure an overlap-aware diarizer exists to avoid. Under a
        // collapsing metric this scores 0.0 and the regression is invisible.
        let ref: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 10),
            .init(speaker: "B", start: 4, end: 8),
        ]
        let hyp: [DERCalculator.Turn] = [.init(speaker: "A", start: 0, end: 10)]
        let result = DERCalculator.derBreakdown(reference: ref, hypothesis: hyp)
        XCTAssertEqual(result.missedSpeech, 4.0, accuracy: 1e-9)
        XCTAssertEqual(result.falseAlarm, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.speakerConfusion, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.der, 4.0 / 14.0, accuracy: 1e-9)
    }

    func test_overlap_inventedSimultaneousSpeaker_isFalseAlarm() {
        let ref: [DERCalculator.Turn] = [.init(speaker: "A", start: 0, end: 10)]
        let hyp: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 10),
            .init(speaker: "B", start: 4, end: 8),
        ]
        let result = DERCalculator.derBreakdown(reference: ref, hypothesis: hyp)
        XCTAssertEqual(result.falseAlarm, 4.0, accuracy: 1e-9)
        XCTAssertEqual(result.missedSpeech, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.der, 0.4, accuracy: 1e-9)
    }

    func test_overlap_rightCountWrongSpeaker_isConfusionNotMissedPlusFalseAlarm() {
        // Two speakers active, two reported, one of them wrong. C is pinned to
        // reference C by its own 12-20 turn, so the optimal mapping cannot
        // rescue it by renaming — during 4-8 it is genuinely the wrong speaker.
        // (Substituting a FRESH label there would be a pure relabelling, which
        // DER is right to score 0; speaker identifiers are arbitrary.)
        let ref: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 10),
            .init(speaker: "B", start: 4, end: 8),
            .init(speaker: "C", start: 12, end: 20),
        ]
        let hyp: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 10),
            .init(speaker: "C", start: 4, end: 8),
            .init(speaker: "C", start: 12, end: 20),
        ]
        let result = DERCalculator.derBreakdown(reference: ref, hypothesis: hyp)
        XCTAssertEqual(result.speakerConfusion, 4.0, accuracy: 1e-9)
        XCTAssertEqual(result.missedSpeech, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.falseAlarm, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.totalReference, 22.0, accuracy: 1e-9)
        XCTAssertEqual(result.der, 4.0 / 22.0, accuracy: 1e-9)
    }

    func test_overlap_freshLabelForASimultaneousSpeaker_isPureRelabelling() {
        // The control for the test above: DER must stay 0 when the only
        // difference is which arbitrary string names the second speaker.
        let ref: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 10),
            .init(speaker: "B", start: 4, end: 8),
        ]
        let hyp: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 10),
            .init(speaker: "C", start: 4, end: 8),
        ]
        XCTAssertEqual(DERCalculator.der(reference: ref, hypothesis: hyp), 0.0, accuracy: 1e-9)
    }

    func test_overlap_threeSimultaneousSpeakers_countAllThree() {
        let ref: [DERCalculator.Turn] = [
            .init(speaker: "A", start: 0, end: 10),
            .init(speaker: "B", start: 2, end: 6),
            .init(speaker: "C", start: 3, end: 5),
        ]
        let result = DERCalculator.derBreakdown(reference: ref, hypothesis: ref)
        XCTAssertEqual(result.totalReference, 16.0, accuracy: 1e-9)
        XCTAssertEqual(result.der, 0.0, accuracy: 1e-9)
    }
}
