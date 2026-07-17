#if !APPSTORE
    // `@preconcurrency`: ApplicationServices AX globals lack Sendable annotations
    // (same gap AXHelper/Permissions guard).
    @preconcurrency import ApplicationServices

    /// Shared HIServices accessibility plumbing for the in-process `/ui/*`
    /// endpoints (`/ui/tree`, `/ui/press`). Reads the app's OWN accessibility tree
    /// via `AXUIElementCreateApplication(getpid())`.
    ///
    /// Why the AX C API and not `NSView.accessibilityChildren()`: SwiftUI builds
    /// its accessibility tree lazily, materialized only when a HIServices AX query
    /// arrives — the in-process `NSAccessibility` protocol walk from a hosting
    /// view returns an empty tree and never surfaces `.accessibilityIdentifier`.
    /// The self-pid AX path is what VoiceOver/XCUITest use, here targeting our own
    /// process; HIServices short-circuits a self-pid target into a direct
    /// in-process call, so it needs NO Accessibility TCC grant (that grant gates
    /// only cross-process access; self-inspection is exempt — verified against a
    /// never-granted build). One hard rule: because the call dispatches on the
    /// *calling* thread and SwiftUI's action handlers assert `MainActor`, every
    /// read and especially every press must run on the main actor. These are
    /// static methods on the `@MainActor` `DebugRPCServer`, so that holds.
    ///
    /// `AXIdentifier` carries `.accessibilityIdentifier`; the visible label is
    /// `AXDescription` (falling back to `AXTitle`).
    ///
    /// Fallback if a future macOS breaks the self-pid fast path (either the
    /// direct-dispatch shortcut or the TCC self-exemption — both empirical, not
    /// contractual): these same `ax*` helpers work unchanged against another
    /// process's element, so they can move into an out-of-process client (`mt-cli`
    /// targeting the app's pid) holding a one-time Accessibility grant keyed on the
    /// stable signing cert — the documented cross-process assistive-client path
    /// VoiceOver uses. A `/ui/*` smoke assertion in a nightly lane should guard the
    /// fast path so an OS update that breaks it fails loudly and attributably.
    extension DebugRPCServer {
        static func axRole(_ element: AXUIElement) -> String? {
            AXHelper.getAttribute(element, attribute: kAXRoleAttribute as String) as? String
        }

        static func axIdentifier(_ element: AXUIElement) -> String? {
            guard let identifier = AXHelper.getAttribute(element, attribute: "AXIdentifier") as? String,
                  !identifier.isEmpty else { return nil }
            return identifier
        }

        /// Visible label — `AXDescription` first (SwiftUI's `.accessibilityLabel` /
        /// control title lands here), then `AXTitle`.
        static func axLabel(_ element: AXUIElement) -> String? {
            (AXHelper.getAttribute(element, attribute: kAXDescriptionAttribute as String) as? String)
                ?? (AXHelper.getAttribute(element, attribute: kAXTitleAttribute as String) as? String)
        }

        /// Defaults to enabled when the attribute is absent — a container without
        /// an explicit `AXEnabled` is treated as interactive, matching AppKit.
        static func axEnabled(_ element: AXUIElement) -> Bool {
            (AXHelper.getAttribute(element, attribute: kAXEnabledAttribute as String) as? Bool) ?? true
        }

        /// Frame in AX coordinates: top-left-origin global screen points (Quartz),
        /// which differ from AppKit's bottom-left origin — mind that when
        /// correlating with a `/screenshot` PNG.
        static func axFrame(_ element: AXUIElement) -> CGRect {
            var origin = CGPoint.zero
            var size = CGSize.zero
            if let raw = axValue(element, attribute: kAXPositionAttribute as String) {
                _ = AXValueGetValue(raw, .cgPoint, &origin)
            }
            if let raw = axValue(element, attribute: kAXSizeAttribute as String) {
                _ = AXValueGetValue(raw, .cgSize, &size)
            }
            return CGRect(origin: origin, size: size)
        }

        static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
            AXHelper.getAttribute(element, attribute: kAXChildrenAttribute as String) as? [AXUIElement] ?? []
        }

        /// Fire the element's press action. Returns whether HIServices reports the
        /// action ran. MUST run on the main actor (SwiftUI action handlers assert
        /// `MainActor`); `DebugRPCServer`'s isolation enforces that.
        static func axPress(_ element: AXUIElement) -> Bool {
            AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }

        /// The app's window with the given `AXIdentifier` (our `NSWindow`
        /// identifier surfaces there), or nil when no such window is open. Scopes a
        /// tree walk / press to one window out of the app-wide AX tree (which also
        /// contains the menu bar).
        static func axWindowElement(forIdentifier identifier: String) -> AXUIElement? {
            let app = AXUIElementCreateApplication(getpid())
            let windows = AXHelper.getAttribute(app, attribute: kAXWindowsAttribute as String) as? [AXUIElement] ?? []
            return windows.first { axIdentifier($0) == identifier }
        }

        /// The attribute as an `AXValue` (geometry attributes like position/size),
        /// or nil when absent or not an `AXValue`.
        private static func axValue(_ element: AXUIElement, attribute: String) -> AXValue? {
            guard let raw = AXHelper.getAttribute(element, attribute: attribute),
                  CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            // swiftlint:disable:next force_cast
            return (raw as! AXValue)
        }
    }
#endif
