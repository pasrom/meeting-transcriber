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
/// trade-off: very long captions clip vertically once they exceed the
/// preset's panel height; that's acceptable for the PoC and the surrounding
/// overlay only renders a few lines anyway. The dimensions come from
/// `LiveCaptionsSize` (Settings → Transcription → Caption size), which pairs
/// each panel size with the font it was measured for; `apply(size:)` swaps
/// both together.
@MainActor
final class LiveCaptionsWindowController {
    private var panel: NSPanel?
    private let state: LiveCaptionsState
    private var size: LiveCaptionsSize

    private var modifierMonitor: Any?
    private var moveObserver: (any NSObjectProtocol)?

    /// Where the panel origin is persisted. Production passes nothing and
    /// gets `.standard`; tests inject a suite so they never touch the real
    /// saved position.
    private let defaults: UserDefaults

    private static let bottomMargin: CGFloat = 60

    /// UserDefaults key for the bottom-left origin of the panel. Stored as
    /// `{"x": Double, "y": Double}`; absence means "first run, use default
    /// bottom-centre of main screen".
    static let originDefaultsKey = "liveCaptionsPanelOrigin"

    init(state: LiveCaptionsState, size: LiveCaptionsSize = .medium, defaults: UserDefaults = .standard) {
        self.state = state
        self.size = size
        self.defaults = defaults
        state.setSize(size)
    }

    /// Show the caption bar (creating the panel lazily on first call).
    func show() {
        let panel = ensurePanel()
        positionAtSavedOrDefault(panel)
        panel.orderFrontRegardless()
    }

    /// Switch presets. The overlay's font and the panel's frame change in one
    /// step so neither can be observed at the other's old size, and the bar
    /// keeps its bottom edge and horizontal centre (see `resizedFrame`).
    ///
    /// The saved origin is updated on both paths. With a panel, it is
    /// persisted here rather than left to the move observer because a
    /// `setFrame` that changes the size posts no `didMoveNotification` at all
    /// (measured: 0 of 36 runs), so the observer could never catch it.
    /// Without a panel, which is the common case for a preset change made in
    /// Settings before the first recording (the controller exists from
    /// launch, the panel only from the first recording), the origin saved by
    /// an earlier session is a bottom-left corner for the old width; it is
    /// re-centred for the new width so the next `show()` puts the bar's
    /// centre where the user left it.
    func apply(size: LiveCaptionsSize) {
        guard size != self.size else { return }
        let previous = self.size
        self.size = size
        state.setSize(size)
        if let panel {
            panel.setFrame(Self.resizedFrame(panel.frame, to: size, within: panel.screen?.visibleFrame), display: true)
            persistOrigin(panel.frame.origin)
        } else if let saved = storedOrigin() {
            let frame = NSRect(origin: saved, size: previous.panelSize)
            persistOrigin(Self.resizedFrame(frame, to: size, within: nil).origin)
        }
    }

    /// The frame a panel at `frame` takes when switched to `size`: same
    /// bottom edge, same horizontal centre. Anchoring the bottom-left corner
    /// instead would walk the bar sideways on every preset change, since the
    /// user parks it by eye at the bottom-centre of a call window.
    ///
    /// The result is pushed back inside `screen` when one is given: AppKit
    /// does not constrain a borderless non-activating panel (measured:
    /// `constrainFrameRect` returns the target unchanged), so a bar parked
    /// flush against a side edge would otherwise grow past it by half the
    /// width delta.
    static func resizedFrame(_ frame: NSRect, to size: LiveCaptionsSize, within screen: NSRect?) -> NSRect {
        var resized = NSRect(
            x: frame.midX - size.panelSize.width / 2,
            y: frame.minY,
            width: size.panelSize.width,
            height: size.panelSize.height,
        )
        guard let screen else { return resized }
        resized.origin.x = min(max(resized.minX, screen.minX), screen.maxX - resized.width)
        resized.origin.y = min(max(resized.minY, screen.minY), screen.maxY - resized.height)
        return resized
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
            contentRect: NSRect(origin: .zero, size: size.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        panel.contentView = host
        // Stable identifier so the panel is addressable by window-id lookups
        // (mirrors the SwiftUI `Window(id:)` scenes). Not yet exposed to the
        // debug `/ui/tree` allowlist — it can surface meeting content.
        panel.identifier = NSUserInterfaceItemIdentifier("live-captions")
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
        panel.setFrame(NSRect(origin: origin, size: size.panelSize), display: true)
    }

    private func defaultBottomCentreOrigin() -> CGPoint {
        guard let screen = NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        return CGPoint(
            x: visible.midX - size.panelSize.width / 2,
            y: visible.minY + Self.bottomMargin,
        )
    }

    /// The saved origin, or nil when none was ever persisted. No screen check:
    /// `apply` re-centres it whether or not that screen is attached right now.
    private func storedOrigin() -> CGPoint? {
        guard let dict = defaults.dictionary(forKey: Self.originDefaultsKey),
              let x = dict["x"] as? Double, let y = dict["y"] as? Double
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Read the saved origin and reject it if no currently-attached screen
    /// contains both top corners of the bar at the current size (handles
    /// "user disconnected the secondary monitor where the bar lived", and a
    /// position saved for a wider screen). Returns nil → caller falls back
    /// to default placement.
    private func savedOrigin() -> CGPoint? {
        guard let candidate = storedOrigin() else { return nil }
        let top = candidate.y + size.panelSize.height
        let corners = [CGPoint(x: candidate.x, y: top), CGPoint(x: candidate.x + size.panelSize.width, y: top)]
        let onScreen = NSScreen.screens.contains { screen in
            corners.allSatisfy { screen.visibleFrame.contains($0) }
        }
        return onScreen ? candidate : nil
    }

    private func persistOrigin(_ origin: CGPoint) {
        defaults.set(
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
