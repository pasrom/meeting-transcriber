import CoreGraphics
@testable import MeetingTranscriber
import XCTest

final class CaptionDragTranslationTests: XCTestCase {
    func testMouseDeltaMovesPanelFromItsStartingOrigin() {
        let drag = CaptionDragTranslation(
            startMouseLocation: CGPoint(x: 320, y: 240),
            startOrigin: CGPoint(x: -180, y: 75),
        )

        XCTAssertEqual(drag.origin(at: CGPoint(x: 350, y: 220)), CGPoint(x: -150, y: 55))
        XCTAssertEqual(drag.origin(at: CGPoint(x: 310, y: 260)), CGPoint(x: -190, y: 95))
    }
}
