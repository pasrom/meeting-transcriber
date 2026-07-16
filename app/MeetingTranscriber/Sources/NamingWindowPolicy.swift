import AppKit

/// Pins the "Name Speakers" window so it stays available while the user works
/// in other apps (issue #504).
///
/// The naming dialog is a "come back and finish me later" task: the user often
/// wants to keep working elsewhere and return to it. As a menu-bar
/// (`LSUIElement`) app we have no Dock icon to reopen a buried window, so if the
/// window is swept off-stage by Stage Manager or displaced by a full-screen
/// Space it reads as "gone" (issue #504). This applies the same recipe the
/// live-captions panel uses (`LiveCaptionsWindowController`), scoped to the
/// naming window only:
///
/// - `hidesOnDeactivate = false` — belt-and-braces; an `NSWindow` already
///   defaults to `false`, but a restored/panel-backed window might not.
/// - `level = .floating` — stays above other apps so it is always one click
///   away (it cannot hold the *key* focus while the user types elsewhere; macOS
///   forbids a background app from doing that).
/// - `.canJoinAllSpaces` + `.fullScreenAuxiliary` — follows the user across
///   Spaces and shows over full-screen apps / Stage Manager instead of being
///   left behind on the Space it opened on.
///
/// `.canJoinAllSpaces` and `.fullScreenAuxiliary` each belong to a
/// mutually-exclusive `NSWindowCollectionBehavior` group, so the conflicting
/// members are cleared before they are unioned in — otherwise AppKit silently
/// ignores the flags we want. SwiftUI's naming window ships with
/// `.fullScreenNone`, which would defeat `.fullScreenAuxiliary` if left set.
/// Unrelated flags are preserved.
enum NamingWindowPolicy {
    @MainActor
    static func apply(to window: NSWindow) {
        window.hidesOnDeactivate = false
        window.level = .floating
        var behavior = window.collectionBehavior
        // Drop the other members of the two exclusive groups we set below.
        behavior.subtract([.managed, .moveToActiveSpace, .stationary, .fullScreenPrimary, .fullScreenNone])
        behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.collectionBehavior = behavior
    }
}
