import AppKit
import SwiftUI

/// Borderless, click-through, status-bar-level NSPanel that hosts the live
/// caption-bar overlay. Pinned to the bottom of the main screen, sits above
/// regular app windows, ignores mouse events so the user can still click
/// through to whatever is below (Teams / Zoom / browser).
///
/// Uses a fixed-size panel (no `sizingOptions = .preferredContentSize`)
/// because auto-sizing produced an infinite layout-feedback loop with the
/// caption-bar content — the SwiftUI hierarchy's ideal size republished on
/// every layout pass, NSHostingController called `setFrame`, which fired
/// another layout, recursing until the stack overflowed. The fixed-size
/// trade-off: very long captions clip vertically once they exceed
/// `panelHeight`; that's acceptable for the PoC and the surrounding overlay
/// only renders a few lines anyway.
///
/// PoC scope: no positioning persistence (always recentred at bottom on
/// show), no fade-on-silence yet, no multi-monitor handling — picks
/// `NSScreen.main`.
@MainActor
final class LiveCaptionsWindowController {
    private var panel: NSPanel?
    private let state: LiveCaptionsState

    private static let panelWidth: CGFloat = 720
    /// Tall enough for 4 lines of 22 pt text plus the rounded-background
    /// padding (14 pt × 2). Lines beyond this clip silently.
    private static let panelHeight: CGFloat = 200
    private static let bottomMargin: CGFloat = 60

    init(state: LiveCaptionsState) {
        self.state = state
    }

    /// Show the caption bar (creating the panel lazily on first call).
    func show() {
        let panel = ensurePanel()
        positionAtBottom(panel)
        panel.orderFrontRegardless()
    }

    /// Hide the caption bar without destroying the panel — re-showing is
    /// cheap and the underlying SwiftUI host stays bound to the same state.
    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let host = NSHostingView(rootView: LiveCaptionsOverlay(state: state))
        host.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: NSRect(
                x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight,
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel
        return panel
    }

    private func positionAtBottom(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let originX = visible.midX - Self.panelWidth / 2
        let originY = visible.minY + Self.bottomMargin
        panel.setFrame(
            NSRect(
                x: originX, y: originY,
                width: Self.panelWidth, height: Self.panelHeight,
            ),
            display: true,
        )
    }
}
