@testable import MeetingTranscriber
import XCTest

final class CaptionDragSessionTests: XCTestCase {
    func testAMoveWithNoDragIsNotSaved() {
        var session = CaptionDragSession()
        XCTAssertFalse(session.shouldSaveMove(buttonPressed: true))
    }

    func testEveryMoveWhileTheButtonIsDownIsSaved() {
        var session = CaptionDragSession()
        session.mouseDown()
        XCTAssertTrue(session.shouldSaveMove(buttonPressed: true))
        XCTAssertTrue(session.shouldSaveMove(buttonPressed: true))
    }

    func testAMouseUpEndsSavingImmediately() {
        var session = CaptionDragSession()
        session.mouseDown()
        session.mouseUp()
        XCTAssertFalse(session.shouldSaveMove(buttonPressed: false))
        XCTAssertFalse(session.shouldSaveMove(buttonPressed: true))
    }

    func testAMissedMouseUpClosesWithoutSavingAnotherMove() {
        var session = CaptionDragSession()
        session.mouseDown()
        XCTAssertTrue(session.shouldSaveMove(buttonPressed: true))
        XCTAssertFalse(session.shouldSaveMove(buttonPressed: false))
        XCTAssertFalse(session.shouldSaveMove(buttonPressed: true))
    }

    func testAResetEndsTheDrag() {
        var session = CaptionDragSession()
        session.mouseDown()
        session.reset()
        XCTAssertFalse(session.shouldSaveMove(buttonPressed: true))
    }

    func testAMouseUpWithoutADownStartsNoSession() {
        var session = CaptionDragSession()
        session.mouseUp()
        XCTAssertFalse(session.shouldSaveMove(buttonPressed: true))
    }

    func testANewDragAfterAnEndedOneIsSavedAgain() {
        var session = CaptionDragSession()
        session.mouseDown()
        session.mouseUp()
        session.mouseDown()
        XCTAssertTrue(session.shouldSaveMove(buttonPressed: true))
    }
}
