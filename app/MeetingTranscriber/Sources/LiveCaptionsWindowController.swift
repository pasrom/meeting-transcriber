import AppKit
import SwiftUI

/// Borderless, click-through, status-bar-level NSPanel that hosts the live
/// caption-bar overlay. By default sits above regular app windows and
/// ignores mouse events so the user can still click through to whatever is
/// below (Teams / Zoom / browser).
///
/// To reposition: hold ⌥ (Option) and drag — the modifier monitor below
/// flips `ignoresMouseEvents` off and `isMovableByWindowBackground` on,
/// then back when the key is released. The post-drag origin is persisted
/// to `UserDefaults` (`liveCaptionsPanelOriginKey`) and a follow-up screen
/// is picked by containing-screen lookup on next launch, so the bar
/// re-appears on the secondary display if that's where the user last
/// parked it.
///
/// Uses a fixed-size panel (no `sizingOptions = .preferredContentSize`)
/// because auto-sizing produced an infinite layout-feedback loop with the
/// caption-bar content — the SwiftUI hierarchy's ideal size republished on
/// every layout pass, NSHostingController called `setFrame`, which fired
/// another layout, recursing until the stack overflowed. The fixed-size
/// trade-off: very long captions clip vertically once they exceed
/// `panelHeight`; that's acceptable for the PoC and the surrounding overlay
/// only renders a few lines anyway.
@MainActor
final class LiveCaptionsWindowController {
    private var panel: NSPanel?
    private let state: LiveCaptionsState

    private var modifierMonitor: Any?
    private var moveObserver: (any NSObjectProtocol)?

    private static let panelWidth: CGFloat = 720
    /// Tall enough for 4 lines of 22 pt text plus the rounded-background
    /// padding (14 pt × 2). Lines beyond this clip silently.
    private static let panelHeight: CGFloat = 200
    private static let bottomMargin: CGFloat = 60

    /// UserDefaults key for the bottom-left origin of the panel. Stored as
    /// `{"x": Double, "y": Double}`; absence means "first run, use default
    /// bottom-centre of main screen".
    static let originDefaultsKey = "liveCaptionsPanelOrigin"

    init(state: LiveCaptionsState) {
        self.state = state
    }

    /// Show the caption bar (creating the panel lazily on first call).
    func show() {
        let panel = ensurePanel()
        positionAtSavedOrDefault(panel)
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
        installModifierMonitor(for: panel)
        installMoveObserver(for: panel)
        return panel
    }

    /// Position the panel at the last-saved origin (clipped so it stays on
    /// some currently-attached screen), or bottom-centre of the main screen
    /// if no saved origin exists or the screen it lived on is gone.
    private func positionAtSavedOrDefault(_ panel: NSPanel) {
        let origin = savedOrigin() ?? defaultBottomCentreOrigin()
        panel.setFrame(
            NSRect(
                x: origin.x, y: origin.y,
                width: Self.panelWidth, height: Self.panelHeight,
            ),
            display: true,
        )
    }

    private func defaultBottomCentreOrigin() -> CGPoint {
        guard let screen = NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        return CGPoint(
            x: visible.midX - Self.panelWidth / 2,
            y: visible.minY + Self.bottomMargin,
        )
    }

    /// Read the saved origin and reject it if no currently-attached screen
    /// contains its top-left corner (handles "user disconnected the
    /// secondary monitor where the bar lived"). Returns nil → caller falls
    /// back to default placement.
    private func savedOrigin() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard let dict = defaults.dictionary(forKey: Self.originDefaultsKey),
              let x = dict["x"] as? Double, let y = dict["y"] as? Double
        else { return nil }
        let candidate = CGPoint(x: x, y: y)
        let topLeft = CGPoint(x: x, y: y + Self.panelHeight)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(topLeft) }
        return onScreen ? candidate : nil
    }

    private func persistOrigin(_ origin: CGPoint) {
        UserDefaults.standard.set(
            ["x": origin.x, "y": origin.y],
            forKey: Self.originDefaultsKey,
        )
    }

    /// Watch ⌥ (Option). While held, flip the panel into drag-friendly mode;
    /// release returns it to click-through. Uses both local + global
    /// monitors so the key works whether or not our app is frontmost. The
    /// NSEvent callbacks are not @MainActor-isolated, so each hop onto the
    /// main actor before touching the panel.
    private func installModifierMonitor(for panel: NSPanel) {
        guard modifierMonitor == nil else { return }
        modifierMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged,
        ) { [weak self, weak panel] event in
            let flags = event.modifierFlags
            Task { @MainActor in
                guard let self, let panel else { return }
                self.applyModifierState(to: panel, flags: flags)
            }
        }
        // Local monitor mirrors the same logic for when our app is frontmost.
        _ = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged,
        ) { [weak self, weak panel] event in
            let flags = event.modifierFlags
            Task { @MainActor in
                guard let self, let panel else { return }
                self.applyModifierState(to: panel, flags: flags)
            }
            return event
        }
    }

    private func applyModifierState(to panel: NSPanel, flags: NSEvent.ModifierFlags) {
        let dragMode = flags.contains(.option)
        panel.ignoresMouseEvents = !dragMode
        panel.isMovableByWindowBackground = dragMode
    }

    private func installMoveObserver(for panel: NSPanel) {
        guard moveObserver == nil else { return }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main,
        ) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel else { return }
                self.persistOrigin(panel.frame.origin)
            }
        }
    }
}
