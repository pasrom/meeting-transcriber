#if !APPSTORE
    import AppKit
    @testable import MeetingTranscriber
    import XCTest

    /// Covers the coordinate flip `POST /ui/press` with `"via":"click"` depends on:
    /// accessibility frames are global with a TOP-left origin, `NSEvent` mouse
    /// locations are global with a BOTTOM-left origin. Getting this wrong sends the
    /// click to a mirrored position, which looks like "the click did nothing".
    final class MouseInjectionTests: XCTestCase {
        @MainActor
        func testFlipsAccessibilityYIntoCocoaScreenSpace() {
            let point = MouseInjection.cocoaScreenPoint(
                fromAXPoint: CGPoint(x: 100, y: 200), primaryScreenHeight: 1000,
            )

            XCTAssertEqual(point.x, 100, "x is shared by both spaces and must not move")
            XCTAssertEqual(point.y, 800, "y must be measured from the bottom instead of the top")
        }

        /// The flip is its own inverse, so a round trip lands back on the original
        /// point — the property that makes a wrong screen height obvious.
        @MainActor
        func testFlipIsSelfInverse() {
            let original = CGPoint(x: 42, y: 137)
            let once = MouseInjection.cocoaScreenPoint(fromAXPoint: original, primaryScreenHeight: 900)
            let twice = MouseInjection.cocoaScreenPoint(fromAXPoint: once, primaryScreenHeight: 900)

            XCTAssertEqual(twice.y, original.y)
        }
    }
#endif
