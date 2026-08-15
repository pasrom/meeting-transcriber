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

        // MARK: - windowPoint (the decision `click` delegates to)

        /// A window at a known frame: AX y is measured from the screen top, the
        /// window frame from the bottom, so this pins the whole chain rather than
        /// the arithmetic alone.
        @MainActor
        private func makeWindow(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSWindow {
            NSWindow(
                contentRect: NSRect(x: x, y: y, width: width, height: height),
                styleMask: [.titled], backing: .buffered, defer: true,
            )
        }

        @MainActor
        func testResolvesAnAXPointInsideTheWindow() throws {
            // Screen 1000 tall; window occupies Cocoa y 400...600, i.e. AX y 400...600.
            let window = makeWindow(x: 100, y: 400, width: 200, height: 200)

            let point = try XCTUnwrap(MouseInjection.windowPoint(
                forAXPoint: CGPoint(x: 150, y: 500), in: window, primaryScreenHeight: 1000,
            ))

            // AX y 500 -> Cocoa y 500 -> 100 above the window's bottom edge.
            XCTAssertEqual(point.x, 50, "x is window-relative")
            XCTAssertEqual(point.y, 100, "y is measured from the window's bottom edge")
        }

        /// The guard that matters: a point outside the window is refused rather than
        /// clicked. Without it a stale accessibility frame — the window moved or the
        /// sidebar scrolled since the read — would click whatever now sits there.
        @MainActor
        func testRefusesAnAXPointOutsideTheWindow() {
            let window = makeWindow(x: 100, y: 400, width: 200, height: 200)

            XCTAssertNil(MouseInjection.windowPoint(
                forAXPoint: CGPoint(x: 150, y: 900), in: window, primaryScreenHeight: 1000,
            ), "a point below the window must not resolve")
            XCTAssertNil(MouseInjection.windowPoint(
                forAXPoint: CGPoint(x: 900, y: 500), in: window, primaryScreenHeight: 1000,
            ), "a point right of the window must not resolve")
        }

        /// Fail closed: with no running application there is nothing to post to, so
        /// the caller is told the click did not happen instead of assuming it did.
        @MainActor
        func testClickReportsFailureWithoutAnApplication() throws {
            // Skip rather than fail: `NSApplication.shared` is process-global and
            // irreversible, so a sibling test that touched it invalidates this
            // premise for every later test in the same process. CI runs
            // `swift test --parallel`, which gives each class its own process, so
            // the assertion below still runs there.
            try XCTSkipUnless(NSApp == nil, "another test already created the shared NSApplication")
            let window = makeWindow(x: 0, y: 0, width: 100, height: 100)

            XCTAssertFalse(MouseInjection.click(atAXPoint: CGPoint(x: 10, y: 10), in: window))
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
