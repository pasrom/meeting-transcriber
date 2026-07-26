#if !APPSTORE
    import AppKit
    @testable import MeetingTranscriber
    import XCTest

    /// Covers which `NSWindow` the `/ui/*` endpoints post events into.
    ///
    /// The accessibility tree lists only on-screen windows, but `NSApp.windows`
    /// keeps closed ones. Picking the first identifier match can therefore hand out
    /// a dead window while `axFocus` acted on the live one: focus moves, the events
    /// go nowhere, and the endpoint still reports that it dispatched them.
    @MainActor
    final class DebugRPCServerWindowResolutionTests: XCTestCase {
        private func makeWindow(id: String, visible: Bool) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                styleMask: [.titled], backing: .buffered, defer: true,
            )
            window.identifier = NSUserInterfaceItemIdentifier(id)
            if visible {
                window.orderFront(nil)
            }
            return window
        }

        func testPrefersTheVisibleWindowOverAClosedOneWithTheSameIdentifier() {
            let closed = makeWindow(id: "settings", visible: false)
            let live = makeWindow(id: "settings", visible: true)

            let resolved = DebugRPCServer.visibleWindow(identifier: "settings", among: [closed, live])

            XCTAssertIdentical(resolved, live, "must resolve the on-screen window, not the lingering one")
        }

        func testYieldsNothingWhenEveryMatchIsOffScreen() {
            let closed = makeWindow(id: "settings", visible: false)

            XCTAssertNil(DebugRPCServer.visibleWindow(identifier: "settings", among: [closed]))
        }

        func testIgnoresOtherIdentifiers() {
            let other = makeWindow(id: "speaker-naming", visible: true)

            XCTAssertNil(DebugRPCServer.visibleWindow(identifier: "settings", among: [other]))
        }
    }
#endif
