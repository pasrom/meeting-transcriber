@testable import MeetingTranscriber
import XCTest

/// Which panel moves are the user's drag and get saved. Times are plain
/// seconds on one monotonic clock, as the controller feeds them.
final class CaptionDragSessionTests: XCTestCase {
    private let settle = CaptionDragSession.settleWindow

    func testAMoveWithNoDragIsNotSaved() {
        var session = CaptionDragSession()
        XCTAssertFalse(session.shouldSaveMove(at: 10, buttonPressed: false))
    }

    /// Every move while the button is down is saved, however long the drag
    /// lasts and whatever the Option key does meanwhile: the panel keeps
    /// following the mouse after Option is released.
    func testEveryMoveWhileTheButtonIsDownIsSaved() {
        var session = CaptionDragSession()
        session.mouseDown()
        for time in [10.0, 10.1, 12.0, 30.0] {
            XCTAssertTrue(session.shouldSaveMove(at: time, buttonPressed: true), "at \(time)")
        }
    }

    /// After mouse-up the panel keeps sliding for a few hundred milliseconds,
    /// often to a screen edge, and where it comes to rest is what must be
    /// saved. Each move inside the settle window extends it.
    func testTheSlideAfterMouseUpIsSavedAndEachMoveExtendsTheWindow() {
        var session = CaptionDragSession()
        session.mouseDown()
        session.mouseUp(at: 20)
        XCTAssertTrue(session.shouldSaveMove(at: 20 + settle * 0.9, buttonPressed: false))
        XCTAssertTrue(session.shouldSaveMove(at: 20 + settle * 1.8, buttonPressed: false))
        XCTAssertTrue(session.shouldSaveMove(at: 20 + settle * 2.7, buttonPressed: false))
    }

    /// Once the settle window passes with no move, the drag is over: a later
    /// move (the system relocating the panel, a placement) is not saved, and
    /// does not reopen the window either.
    func testTheSessionEndsWhenTheSettleWindowPassesWithoutAMove() {
        var session = CaptionDragSession()
        session.mouseDown()
        session.mouseUp(at: 20)
        XCTAssertFalse(session.shouldSaveMove(at: 20 + settle * 1.1, buttonPressed: false))
        XCTAssertFalse(session.shouldSaveMove(at: 20 + settle * 1.2, buttonPressed: false))
    }

    /// A mouse-up the panel never saw (or one processed late after a stall
    /// of the main thread) must not lose the drag: the first move with the
    /// button physically up is taken as the mouse-up, is saved, and starts
    /// the settle window. Once that passes without a move, the session is
    /// closed.
    func testAMissedMouseUpSavesTheFirstMoveWithTheButtonUpAndThenCloses() {
        var session = CaptionDragSession()
        session.mouseDown()
        XCTAssertTrue(session.shouldSaveMove(at: 10, buttonPressed: true))
        XCTAssertTrue(session.shouldSaveMove(at: 100, buttonPressed: false))
        XCTAssertFalse(session.shouldSaveMove(at: 100 + settle * 1.1, buttonPressed: false))
    }

    /// With the mouse-up missed, the slide after it (moves arriving with the
    /// button already up, as measured) is still saved and extends the window.
    func testAMissedMouseUpStillSavesTheSlide() {
        var session = CaptionDragSession()
        session.mouseDown()
        XCTAssertTrue(session.shouldSaveMove(at: 10, buttonPressed: true))
        XCTAssertTrue(session.shouldSaveMove(at: 10 + settle * 0.9, buttonPressed: false))
        XCTAssertTrue(session.shouldSaveMove(at: 10 + settle * 1.8, buttonPressed: false))
        XCTAssertFalse(session.shouldSaveMove(at: 10 + settle * 3, buttonPressed: false))
    }

    /// A reset (the panel shown or hidden) ends any drag at once.
    func testAResetEndsTheDrag() {
        var session = CaptionDragSession()
        session.mouseDown()
        session.reset()
        XCTAssertFalse(session.shouldSaveMove(at: 9.1, buttonPressed: true))
        session.mouseDown()
        session.mouseUp(at: 10.1)
        session.reset()
        XCTAssertFalse(session.shouldSaveMove(at: 10.2, buttonPressed: false))
    }

    /// A mouse-up whose mouse-down was not on the panel starts nothing.
    func testAMouseUpWithoutADownStartsNoSession() {
        var session = CaptionDragSession()
        session.mouseUp(at: 20)
        XCTAssertFalse(session.shouldSaveMove(at: 20.1, buttonPressed: false))
    }

    /// A new drag after an ended one is a session of its own.
    func testANewDragAfterAnEndedOneIsSavedAgain() {
        var session = CaptionDragSession()
        session.mouseDown()
        session.mouseUp(at: 20)
        XCTAssertFalse(session.shouldSaveMove(at: 30, buttonPressed: false))
        session.mouseDown()
        XCTAssertTrue(session.shouldSaveMove(at: 31, buttonPressed: true))
    }
}
