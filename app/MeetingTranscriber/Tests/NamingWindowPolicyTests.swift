import AppKit
@testable import MeetingTranscriber
import XCTest

/// Unit coverage for the pinning policy applied to the "Name Speakers" window
/// so it survives app deactivation, Stage Manager, and full-screen Spaces
/// (issue #504). Driving real scene deactivation is not possible from a
/// pure-SPM XCTest target, so we test the pure `apply(to:)` seam against a
/// real headless `NSWindow` instead.
@MainActor
final class NamingWindowPolicyTests: XCTestCase {
    /// Build a window whose relevant properties start in the OPPOSITE of the
    /// pinned state, so each assertion proves `apply` actually changed it (an
    /// identity stub would leave `hidesOnDeactivate == true` and fail).
    ///
    /// The seeded `collectionBehavior` deliberately carries flags that are
    /// mutually exclusive with the ones `apply` sets: `.fullScreenNone` (same
    /// group as `.fullScreenAuxiliary`) and `.managed` (same group as
    /// `.canJoinAllSpaces`). SwiftUI's real naming window ships with
    /// `.fullScreenNone`, so a naive `formUnion` would leave a documented-
    /// invalid combination. `.ignoresCycle` is an unrelated bit that must
    /// survive untouched.
    private func makeUnpinnedWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true,
        )
        window.hidesOnDeactivate = true
        window.level = .normal
        window.collectionBehavior = [.managed, .fullScreenNone, .ignoresCycle]
        return window
    }

    func testKeepsWindowVisibleWhenAppDeactivates() {
        let window = makeUnpinnedWindow()
        NamingWindowPolicy.apply(to: window)
        XCTAssertFalse(
            window.hidesOnDeactivate,
            "Naming window must not hide when the app loses focus (#504)",
        )
    }

    func testFloatsAboveOtherAppWindows() {
        let window = makeUnpinnedWindow()
        NamingWindowPolicy.apply(to: window)
        XCTAssertEqual(
            window.level, .floating,
            "Naming window should stay on top so it is always one click away",
        )
    }

    func testJoinsAllSpacesAndFullScreen() {
        let window = makeUnpinnedWindow()
        NamingWindowPolicy.apply(to: window)
        XCTAssertTrue(
            window.collectionBehavior.contains(.canJoinAllSpaces),
            "Naming window should follow the user across Spaces",
        )
        XCTAssertTrue(
            window.collectionBehavior.contains(.fullScreenAuxiliary),
            "Naming window should show over full-screen apps / Stage Manager",
        )
    }

    func testClearsConflictingSpaceAndFullScreenBits() {
        let window = makeUnpinnedWindow()
        NamingWindowPolicy.apply(to: window)
        // `.canJoinAllSpaces` / `.fullScreenAuxiliary` are each in a
        // mutually-exclusive group; the conflicting members must be removed,
        // otherwise AppKit silently ignores the flags we want.
        XCTAssertFalse(
            window.collectionBehavior.contains(.managed),
            "conflicting Space-participation bit must be cleared",
        )
        XCTAssertFalse(
            window.collectionBehavior.contains(.fullScreenNone),
            "conflicting full-screen bit must be cleared so .fullScreenAuxiliary takes effect",
        )
    }

    func testPreservesUnrelatedCollectionBehaviorBits() {
        let window = makeUnpinnedWindow()
        NamingWindowPolicy.apply(to: window)
        XCTAssertTrue(
            window.collectionBehavior.contains(.ignoresCycle),
            "apply must not clobber unrelated collection-behavior flags",
        )
    }

    /// `WindowAccessor.updateNSView` re-applies the policy on every SwiftUI
    /// update, so applying twice must land on the same state.
    func testIsIdempotent() {
        let window = makeUnpinnedWindow()
        NamingWindowPolicy.apply(to: window)
        let afterFirst = window.collectionBehavior
        NamingWindowPolicy.apply(to: window)
        XCTAssertEqual(window.collectionBehavior, afterFirst)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertEqual(window.level, .floating)
    }
}
