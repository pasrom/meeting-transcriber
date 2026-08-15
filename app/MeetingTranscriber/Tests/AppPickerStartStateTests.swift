@testable import MeetingTranscriber
import XCTest

/// The picker's start decision, exercised as a value so the view test can stay a
/// single wiring assertion.
final class AppPickerStartStateTests: XCTestCase {
    func testReadyOnlyWithASelectionAndNoRecording() {
        XCTAssertEqual(
            AppPickerStartState.resolve(hasSelection: true, startWouldBeRefused: false),
            .ready,
        )
    }

    func testNoSelectionBlocks() {
        XCTAssertEqual(
            AppPickerStartState.resolve(hasSelection: false, startWouldBeRefused: false),
            .noSelection,
        )
    }

    /// True for both halves of the controller's predicate: a start still in
    /// flight and a loop already recording. Both are reachable, because the menu
    /// gates opening this window, not its persistence.
    func testARefusedStartBlocks() {
        XCTAssertEqual(
            AppPickerStartState.resolve(hasSelection: true, startWouldBeRefused: true),
            .manualRecordingActive,
        )
    }

    /// Precedence, not an accident: with both blockers present, telling the user
    /// to pick an app would send them the wrong way, since picking one changes
    /// nothing while a recording owns the loop.
    func testARefusedStartOutranksAMissingSelection() {
        XCTAssertEqual(
            AppPickerStartState.resolve(hasSelection: false, startWouldBeRefused: true),
            .manualRecordingActive,
        )
    }

    func testOnlyReadyAllowsStart() {
        XCTAssertTrue(AppPickerStartState.ready.allowsStart)
        XCTAssertFalse(AppPickerStartState.noSelection.allowsStart)
        XCTAssertFalse(AppPickerStartState.manualRecordingActive.allowsStart)
    }

    /// A missing selection is visible on screen; a recording running behind the
    /// picker is not, so that is the only case that gets words.
    func testOnlyTheRecordingCaseExplainsItself() {
        XCTAssertNil(AppPickerStartState.ready.explanation)
        XCTAssertNil(AppPickerStartState.noSelection.explanation)
        XCTAssertNotNil(AppPickerStartState.manualRecordingActive.explanation)
    }
}
