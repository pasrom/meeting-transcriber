#if !APPSTORE
    import AppKit
    @testable import MeetingTranscriber
    import SwiftUI
    import XCTest

    /// Layer-1 cover for the mechanism `POST /ui/type` is built on: posting key
    /// events through a window's responder chain updates a SwiftUI `TextField`'s
    /// binding.
    ///
    /// This is the load-bearing platform assumption of the endpoint, and it is
    /// specifically *not* the obvious one: setting the accessibility value
    /// (`kAXValueAttribute`) does **not** fire the binding, which is why the
    /// harness exposes no `/ui/setValue`. A posted key event goes through
    /// `keyDown:` → `insertText:`, which the binding does observe. If a future
    /// macOS release breaks that, this test goes red with a precise cause rather
    /// than leaving the endpoint silently inert.
    @MainActor
    final class KeyboardInjectionTests: XCTestCase {
        /// Reference box the SwiftUI binding writes back to, so the test reads the
        /// typed value without reaching into SwiftUI's private state.
        private final class Box { var value = "" }

        private struct Probe: View {
            let box: Box
            var body: some View {
                TextField("", text: Binding(get: { box.value }, set: { box.value = $0 }))
            }
        }

        /// Pump the run loop until `condition` holds or the deadline passes, so
        /// the test waits on the state it actually needs instead of a fixed sleep.
        private func pump(timeout: TimeInterval = 5, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }

        private func firstTextInput(in view: NSView) -> NSView? {
            if view is NSTextField || view is NSTextView {
                return view
            }
            for sub in view.subviews {
                if let found = firstTextInput(in: sub) {
                    return found
                }
            }
            return nil
        }

        /// Host the probe field in a key window and focus it, mirroring what
        /// `/ui/type` does via `axFocus` before injecting.
        private func makeFocusedProbe() throws -> (Box, NSWindow) {
            let box = Box()
            let hosting = NSHostingView(rootView: Probe(box: box))
            hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
            let window = NSWindow(
                contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false,
            )
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)

            // SwiftUI builds its backing NSView tree on a later run-loop turn.
            pump { hosting.subviews.isEmpty == false && self.firstTextInput(in: hosting) != nil }
            let field = try XCTUnwrap(firstTextInput(in: hosting), "SwiftUI TextField never materialised a text view")
            XCTAssertTrue(window.makeFirstResponder(field), "field must accept first responder before typing")
            return (box, window)
        }

        func testPostedKeyEventsUpdateTextFieldBinding() throws {
            let (box, window) = try makeFocusedProbe()

            KeyboardInjection.type("hi", into: window)
            pump { box.value == "hi" }

            XCTAssertEqual(box.value, "hi", "posted key events must drive the SwiftUI binding")
        }

        /// Refocusing a populated field selects its contents, so typing straight
        /// after a focus change REPLACES them. `/ui/type` calls `axFocus` before
        /// every injection, so without deliberate caret placement the same request
        /// would append or replace depending on whether the field happened to be
        /// focused already. This pins the platform half of that; `moveToEnd` is
        /// what makes the endpoint deterministic.
        func testRefocusSelectsContentsSoRawTypingReplaces() throws {
            let (box, window) = try makeFocusedProbe()
            KeyboardInjection.type("abc", into: window)
            pump { box.value == "abc" }

            try refocusField(in: window)
            KeyboardInjection.type("X", into: window)
            pump { box.value != "abc" }

            XCTAssertEqual(box.value, "X", "a refocused field starts fully selected")
        }

        /// The append path: collapsing the selection first keeps existing text.
        func testMoveToEndAppendsInsteadOfReplacing() throws {
            let (box, window) = try makeFocusedProbe()
            KeyboardInjection.type("abc", into: window)
            pump { box.value == "abc" }

            try refocusField(in: window)
            XCTAssertTrue(KeyboardInjection.moveToEnd(in: window), "responder must accept moveToEndOfDocument:")
            KeyboardInjection.type("X", into: window)
            pump { box.value != "abc" }

            XCTAssertEqual(box.value, "abcX", "collapsing the selection to the end must append")
        }

        /// Drop and re-take focus, the way a second `/ui/type` request does.
        private func refocusField(in window: NSWindow) throws {
            XCTAssertTrue(window.makeFirstResponder(nil))
            let contentView = try XCTUnwrap(window.contentView)
            let field = try XCTUnwrap(firstTextInput(in: contentView))
            XCTAssertTrue(window.makeFirstResponder(field))
        }

        /// `clear` must genuinely replace. This pins the reason `selectAll` sends a
        /// responder action instead of posting Cmd-A: a Cmd-A key equivalent needs
        /// a matching main-menu item, which this window (and the xctest process)
        /// does not have, so it silently no-ops and the field APPENDS — measured as
        /// "abcX" before the fix.
        func testSelectAllReplacesInsteadOfAppending() throws {
            let (box, window) = try makeFocusedProbe()
            KeyboardInjection.type("abc", into: window)
            pump { box.value == "abc" }

            XCTAssertTrue(KeyboardInjection.selectAll(in: window), "responder must accept selectAll:")
            KeyboardInjection.type("X", into: window)
            pump { box.value == "X" }

            XCTAssertEqual(box.value, "X", "select-all then typing must replace, not append")
        }
    }
#endif
