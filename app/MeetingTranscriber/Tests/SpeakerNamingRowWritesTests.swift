@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Cover for the two per-row writes in `SpeakerNamingView` that nothing could
/// observe before: which row a "More…" press expands, and which row a
/// suggestion chip's name lands in.
///
/// Both are the shape of defect that issue #700 was, a write reaching the
/// wrong row, and neither was assertable while the row state lived in `@State`.
/// Why that is, and what it rules out, is in CLAUDE.md's GUI Testing section,
/// rung 2; `SpeakerNamingRowState` is the object that makes these tests
/// possible.
@MainActor
final class SpeakerNamingRowWritesTests: XCTestCase {
    // MARK: - Fixture

    /// Two rows, so every assertion can name a row that must NOT have changed.
    private static let labelA = "SPEAKER_00"
    private static let labelB = "SPEAKER_01"
    /// Ten known names against a collapsed limit of eight, so both rows render
    /// a "More (2)…" control and the expanded list is distinguishable from the
    /// collapsed one by the two names only it shows.
    private static let known = (0 ..< 10).map { "Known\($0)" }
    private static let participant = "Dana"

    private func makeData() -> PipelineQueue.SpeakerNamingData {
        PipelineQueue.SpeakerNamingData(
            jobID: UUID(),
            meetingTitle: "Standup",
            // Value == key means "no auto name", so every field starts empty
            // and the chip rows start unfiltered.
            mapping: [Self.labelA: Self.labelA, Self.labelB: Self.labelB],
            speakingTimes: [Self.labelA: 60, Self.labelB: 30],
            embeddings: [:],
            audioPath: nil,
            segments: [],
            participants: [Self.participant],
            isDualSource: false,
        )
    }

    private func makeView(
        onComplete: @escaping (PipelineQueue.SpeakerNamingResult) -> Void = { _ in },
    ) -> SpeakerNamingView {
        SpeakerNamingView(
            data: makeData(),
            knownSpeakerNames: Self.known,
            gracePeriod: 0,
            onComplete: onComplete,
        )
    }

    // MARK: - Locating a row

    /// The row for `label`: the `GroupBox` containing that label's name field.
    /// By content, not by index: a row's position is not its identity, which
    /// is the whole point of the code under test.
    private func row(
        _ label: String, in view: InspectableView<ViewType.ClassifiedView>,
    ) throws -> InspectableView<ViewType.GroupBox> {
        let match = view.findAll(ViewType.GroupBox.self).first { has(A11yID.speakerName(label), in: $0) }
        return try XCTUnwrap(match, "no row carrying \(A11yID.speakerName(label))")
    }

    private func fieldValue(_ label: String, in view: InspectableView<ViewType.ClassifiedView>) throws -> String {
        try row(label, in: view)
            .find(viewWithAccessibilityIdentifier: A11yID.speakerName(label))
            .textField()
            .input()
    }

    private func has(_ identifier: String, in row: InspectableView<ViewType.GroupBox>) -> Bool {
        (try? row.find(viewWithAccessibilityIdentifier: identifier)) != nil
    }

    // MARK: - "More…" expands one row

    func testMorePressExpandsOnlyItsOwnRow() throws {
        let sut = makeView()
        try sut.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.knownMore(Self.labelB))
            .button()
            .tap()

        let after = try sut.inspect()
        let rowB = try row(Self.labelB, in: after)
        let rowA = try row(Self.labelA, in: after)

        XCTAssertTrue(
            has(A11yID.knownName(Self.known[9]), in: rowB),
            "the pressed row must show the names the collapsed list held back",
        )
        XCTAssertTrue(has(A11yID.knownLess(Self.labelB), in: rowB), "the pressed row must offer collapsing again")
        XCTAssertFalse(
            has(A11yID.knownName(Self.known[9]), in: rowA),
            "the other row must stay collapsed: expansion is keyed by label, not shared",
        )
        XCTAssertTrue(has(A11yID.knownMore(Self.labelA), in: rowA), "the other row must still offer expanding")
    }

    func testLessPressCollapsesOnlyItsOwnRow() throws {
        let sut = makeView()
        for label in [Self.labelA, Self.labelB] {
            try sut.inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.knownMore(label))
                .button()
                .tap()
        }
        for label in [Self.labelA, Self.labelB] {
            XCTAssertTrue(
                try has(A11yID.knownLess(label), in: row(label, in: sut.inspect())),
                "precondition: \(label) must be expanded before the collapse",
            )
        }

        try sut.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.knownLess(Self.labelA))
            .button()
            .tap()

        let after = try sut.inspect()
        XCTAssertTrue(
            try has(A11yID.knownMore(Self.labelA), in: row(Self.labelA, in: after)),
            "the collapsed row must offer expanding again",
        )
        XCTAssertTrue(
            try has(A11yID.knownName(Self.known[9]), in: row(Self.labelB, in: after)),
            "the other row must stay expanded",
        )
    }

    // MARK: - A chip writes into its own row

    // The two chip tests deliberately tap different rows: the known chip in the
    // first, the participant chip in the second. A write that always lands in
    // the same row is a plausible defect (a closure capturing the wrong label),
    // and a suite that only ever taps one row would miss it in one direction.

    func testKnownChipWritesIntoItsOwnRowAndConfirmDeliversIt() throws {
        var result: PipelineQueue.SpeakerNamingResult?
        let sut = makeView { result = $0 }
        let name = Self.known[0]

        try row(Self.labelA, in: sut.inspect())
            .find(viewWithAccessibilityIdentifier: A11yID.knownName(name))
            .button()
            .tap()

        let after = try sut.inspect()
        XCTAssertEqual(try fieldValue(Self.labelA, in: after), name, "the chip's name must land in the row it was tapped in")
        XCTAssertEqual(try fieldValue(Self.labelB, in: after), "", "no other row may be written")

        try after.find(button: "Confirm").tap()
        guard case let .confirmed(mapping) = result else {
            XCTFail("Expected .confirmed, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(
            mapping, [Self.labelA: name],
            "Confirm must deliver exactly the name the user picked, under the label whose row it was picked in",
        )
    }

    func testParticipantChipWritesIntoItsOwnRow() throws {
        let sut = makeView()
        let identifier = "\(A11yID.participantNamePrefix)\(Self.participant)"

        try row(Self.labelB, in: sut.inspect())
            .find(viewWithAccessibilityIdentifier: identifier)
            .button()
            .tap()

        let after = try sut.inspect()
        XCTAssertEqual(try fieldValue(Self.labelB, in: after), Self.participant)
        XCTAssertEqual(try fieldValue(Self.labelA, in: after), "", "no other row may be written")
    }

    // MARK: - Re-seeding collapses the rows

    /// Covers the re-seed itself, not the lifecycle that calls it: the trigger
    /// is `.onChange(of: data.revision)`, which needs the SwiftUI lifecycle and
    /// is out of reach here, so nothing pins that a new presentation actually
    /// calls this. What is pinned is the half a caller cannot get right by
    /// accident: a re-seed does not carry an expansion into a different list.
    func testResetCollapsesEveryExpandedRow() {
        let state = SpeakerNamingRowState(names: [Self.labelA: "Carol"])
        state.knownExpanded.insert(Self.labelA)

        state.reset(names: [Self.labelB: ""])

        XCTAssertTrue(state.knownExpanded.isEmpty, "a re-seed must collapse the rows it re-seeds")
        XCTAssertEqual(state.names, [Self.labelB: ""], "and must replace the names rather than merge into them")
    }
}
