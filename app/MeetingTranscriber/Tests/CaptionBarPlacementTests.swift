import CoreGraphics
@testable import MeetingTranscriber
import XCTest

final class CaptionBarPlacementTests: XCTestCase {
    func testDraggedOriginStaysInsideEveryVisibleEdge() {
        let visible = CGRect(x: -1400, y: 80, width: 1200, height: 800)
        let size = CGSize(width: 520, height: 180)
        for (origin, expected) in [
            (CGPoint(x: -1500, y: 10), CGPoint(x: -1400, y: 80)),
            (CGPoint(x: -210, y: 870), CGPoint(x: -720, y: 700)),
            (CGPoint(x: -1000.5, y: 300.5), CGPoint(x: -1000.5, y: 300.5)),
        ] {
            XCTAssertEqual(CaptionBarPlacement.clampedOrigin(origin, size: size, visibleFrame: visible), expected)
        }
    }

    func testDragScreenSelectionIgnoresInvalidScreens() {
        let valid = CaptionScreen(
            frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            visibleFrame: CGRect(x: 0, y: 80, width: 1200, height: 800),
        )
        let invalid = CaptionScreen(frame: valid.frame, visibleFrame: .zero)
        let bar = CGRect(x: 100, y: 100, width: 520, height: 180)

        XCTAssertEqual(CaptionBarPlacement.screenOwning(bar, among: [invalid, valid]), valid)
        XCTAssertNil(CaptionBarPlacement.screenOwning(bar, among: [invalid]))
    }
}
