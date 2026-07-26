#if !APPSTORE
    import AppKit

    /// Clicks a point in the app's own UI by posting real mouse events, backing
    /// `POST /ui/press` with `"via":"click"`.
    ///
    /// Why a synthetic click when an AX press action exists: some SwiftUI controls
    /// accept `kAXPressAction` and report success without the action taking effect.
    /// A `List(selection:)` row is the case that forced this — the identifier lands
    /// on the row's `AXStaticText`, pressing it returns `true`, and the selection
    /// does not change. A posted mouse event goes through real hit-testing, which
    /// is the path that actually drives selection.
    ///
    /// Delivery is `NSApplication.postEvent(_:atStart:)`, so the events never
    /// leave the process: no WindowServer HID path, hence no
    /// Accessibility/PostEvent TCC grant, and no cursor warp (the pointer does not
    /// move, so a click cannot be stolen from whatever the user is doing).
    ///
    /// It must be the event QUEUE and not `NSWindow.sendEvent`: a mouse-down on a
    /// row-tracking control (`NSTableView`, which backs SwiftUI `List`) enters a
    /// modal tracking loop that pulls the matching mouse-up off the queue. Direct
    /// `sendEvent` delivery bypasses the queue, so the tracking loop waits forever
    /// for a mouse-up that is only delivered after it returns — verified live: it
    /// wedges the app's main thread and the RPC server stops answering. Posting
    /// both events and returning lets the run loop feed the tracking loop.
    @MainActor
    enum MouseInjection {
        /// Convert an accessibility point (global, top-left origin, y down) to
        /// Cocoa screen coordinates (global, bottom-left origin, y up).
        ///
        /// Both spaces are anchored on the primary screen — the one whose Cocoa
        /// origin is (0, 0) and against whose top edge AX measures — so the flip
        /// is `primaryHeight - y`. Pure, so the arithmetic is unit-testable
        /// without a screen.
        static func cocoaScreenPoint(fromAXPoint point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
            CGPoint(x: point.x, y: primaryScreenHeight - point.y)
        }

        /// Post a click at `axPoint` (an accessibility frame point) to `window`.
        /// Returns false when the point cannot be mapped into the window, when the
        /// screen list is empty, or when either event cannot be built.
        ///
        /// Both events are constructed BEFORE either is posted. Posting a mouse-down
        /// whose mouse-up never follows leaves the tracking loop waiting for an up
        /// that cannot arrive, which wedges the main thread exactly as described
        /// above, so a half-built pair must never be delivered.
        /// Resolve an accessibility point into `window`'s own coordinate space, or
        /// nil when it falls outside the window.
        ///
        /// Split out of `click` because this is the part that can be subtly wrong —
        /// a bad flip mirrors the click and a stale frame lands it on whatever moved
        /// into that spot — and it is the only part testable without a running
        /// `NSApplication`. Hit-testing, not the validated identifier, decides what a
        /// click actually hits, so refusing out-of-window points is a guard, not a
        /// convenience.
        static func windowPoint(
            forAXPoint axPoint: CGPoint, in window: NSWindow, primaryScreenHeight: CGFloat,
        ) -> CGPoint? {
            let screenPoint = cocoaScreenPoint(
                fromAXPoint: axPoint, primaryScreenHeight: primaryScreenHeight,
            )
            guard window.frame.contains(screenPoint) else { return nil }
            return window.convertPoint(fromScreen: screenPoint)
        }

        static func click(atAXPoint axPoint: CGPoint, in window: NSWindow) -> Bool {
            guard let app = NSApp, let primary = NSScreen.screens.first else { return false }
            guard let windowPoint = windowPoint(
                forAXPoint: axPoint, in: window, primaryScreenHeight: primary.frame.height,
            ) else { return false }
            // A synthetic click on an inactive app is delivered but not acted on:
            // measured against the running app, the sidebar selection did not change
            // and the endpoint still answered `{"pressed":true}`. Making the window
            // key first is what turns the post into an actual hit-test.
            if !window.isKeyWindow {
                app.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            guard let down = mouseEvent(.leftMouseDown, at: windowPoint, in: window),
                  let up = mouseEvent(.leftMouseUp, at: windowPoint, in: window)
            else { return false }
            app.postEvent(down, atStart: false)
            app.postEvent(up, atStart: false)
            return true
        }

        private static func mouseEvent(
            _ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow,
        ) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0,
            )
        }
    }
#endif
