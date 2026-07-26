#if !APPSTORE
    import AppKit
    @testable import MeetingTranscriber
    import SwiftUI
    import XCTest

    /// PoC for the e2e "last mile": prove that a *posted key event* updates a
    /// SwiftUI `TextField`'s binding, unlike an AX set-value (which the `/ui`
    /// harness deliberately does not expose, because AX-set does not fire the
    /// SwiftUI binding). If this is green, the same mechanism is what a future
    /// in-process `/ui/type` endpoint would use to automate the "typing into
    /// fields" acceptance that is currently manual-QA-only.
    ///
    /// The injector is intentionally test-local (not production visibility
    /// widening): slice 1 only establishes the mechanism.
    @MainActor
    final class KeyboardInjectionPoCTests: XCTestCase {
        /// Reference box the SwiftUI binding writes back to, so the test can read
        /// the post-typing value without reaching into SwiftUI's private state.
        private final class Box { var value = "" }

        private struct Probe: View {
            let box: Box
            var body: some View {
                TextField("", text: Binding(get: { box.value }, set: { box.value = $0 }))
            }
        }

        /// Hosts the probe in a real key window, focuses the field, injects the
        /// characters as posted key events, and returns the window so the caller
        /// can pump the run loop before asserting.
        private func makeHostedProbe(_ box: Box) -> NSWindow {
            let hosting = NSHostingView(rootView: Probe(box: box))
            hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.titled], backing: .buffered, defer: false,
            )
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            return window
        }

        func testPostedKeyEventUpdatesTextFieldBinding() {
            let box = Box()
            let window = makeHostedProbe(box)

            // Give SwiftUI a run-loop turn to build its NSView tree + field editor.
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))

            KeyboardInjector.focusFirstTextField(in: window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))

            KeyboardInjector.type("hi", into: window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            XCTAssertEqual(box.value, "hi", "posted key events should drive the SwiftUI binding")
        }
    }

    /// Minimal in-process key-event injector (test-local). Focuses the first
    /// text view in a window and posts real key-down/up events through the
    /// responder chain via `NSWindow.sendEvent` (no `NSApp` dependency, so it
    /// works in the xctest process where `NSApp` is nil).
    @MainActor
    enum KeyboardInjector {
        /// Depth-first search for the field editor's backing text view and make
        /// it first responder.
        static func focusFirstTextField(in window: NSWindow) {
            guard let root = window.contentView else { return }
            if let field = firstTextInput(in: root) {
                window.makeFirstResponder(field)
            }
        }

        private static func firstTextInput(in view: NSView) -> NSView? {
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

        /// Post each character as a key-down + key-up `NSEvent` routed to the
        /// window's first responder.
        static func type(_ text: String, into window: NSWindow) {
            for scalarString in text.map({ String($0) }) {
                for down in [true, false] {
                    guard let event = NSEvent.keyEvent(
                        with: down ? .keyDown : .keyUp,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        characters: scalarString,
                        charactersIgnoringModifiers: scalarString,
                        isARepeat: false,
                        keyCode: 0,
                    ) else { continue }
                    window.sendEvent(event)
                }
            }
        }
    }
#endif
