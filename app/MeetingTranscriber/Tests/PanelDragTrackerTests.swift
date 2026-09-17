@testable import MeetingTranscriber
import XCTest

/// The arithmetic behind moving the caption panel by hand: the point grabbed
/// stays under the cursor for the whole drag.
final class PanelDragTrackerTests: XCTestCase {
    func testOriginFollowsTheMouseKeepingTheGrabOffset() {
        var drag = PanelDragTracker()
        drag.begin(mouse: NSPoint(x: 100, y: 100), frameOrigin: NSPoint(x: 40, y: 30))

        XCTAssertEqual(drag.origin(forMouse: NSPoint(x: 150, y: 120)), NSPoint(x: 90, y: 50))
        XCTAssertEqual(drag.origin(forMouse: NSPoint(x: 90, y: 95)), NSPoint(x: 30, y: 25))
    }

    /// Drag events that arrive without a preceding mouse-down (the window got
    /// them by being the mouse-down window of a click it ignored) move nothing.
    func testNoOriginWithoutABegin() {
        let drag = PanelDragTracker()
        XCTAssertNil(drag.origin(forMouse: NSPoint(x: 10, y: 10)))
    }

    func testEndStopsTheDrag() {
        var drag = PanelDragTracker()
        drag.begin(mouse: .zero, frameOrigin: .zero)
        drag.end()
        XCTAssertNil(drag.origin(forMouse: NSPoint(x: 5, y: 5)))
    }
}
