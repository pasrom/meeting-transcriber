import AppKit
import SwiftUI

/// Borderless, click-through, status-bar-level NSPanel that hosts the live
/// caption-bar overlay. By default sits above regular app windows and
/// ignores mouse events so the user can still click through to whatever is
/// below (Teams / Zoom / browser).
///
/// To reposition: hold ⌥ (Option) and drag — the modifier monitor below
/// flips `ignoresMouseEvents` off and `isMovableByWindowBackground` on,
/// then back when the key is released. Only the user's drag is saved
/// (`originDefaultsKey`, see `CaptionDragSession`), and every `show()` puts
/// the bar back there, moving it only when it could not be reached (see
/// `CaptionBarPlacement`).
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

    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?
    private var mouseMonitor: Any?
    private var dragSession = CaptionDragSession()
    /// Set while the controller moves the panel itself, so the move observer
    /// never saves that, whatever AppKit posts for it.
    private var isPlacing = false
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

    /// The caption panel's window identifier.
    static let panelIdentifier = NSUserInterfaceItemIdentifier("live-captions")

    /// Whether the left mouse button is physically down, and the monotonic
    /// clock the drag session runs on. Production passes nothing; tests
    /// drive both, since events they inject change neither.
    private let buttonPressed: () -> Bool
    private let now: () -> TimeInterval

    init(
        state: LiveCaptionsState,
        size: LiveCaptionsSize = .medium,
        defaults: UserDefaults = .standard,
        buttonPressed: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    ) {
        self.state = state
        self.size = size
        self.defaults = defaults
        self.buttonPressed = buttonPressed
        self.now = now
        state.setSize(size)
    }

    /// Removes the key monitors and the move observer, which would otherwise
    /// outlive a released controller (the app keeps one for its whole life,
    /// tests make many).
    isolated deinit {
        for monitor in [globalModifierMonitor, localModifierMonitor, mouseMonitor].compactMap(\.self) {
            NSEvent.removeMonitor(monitor)
        }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// Show the caption bar (creating the panel lazily on first call).
    func show() {
        let panel = ensurePanel()
        dragSession.reset()
        positionAtSavedOrDefault(panel)
        panel.orderFrontRegardless()
    }

    /// Switch presets. The overlay's font and the panel's frame change in one
    /// step so neither can be observed at the other's old size, and the bar
    /// keeps its bottom edge and horizontal centre (see `resizedFrame`).
    ///
    /// A saved origin is a bottom-left corner for the old width, so it is
    /// re-centred for the new one, with or without a panel, and saved
    /// unclamped; the next `show()` pulls a bar that grew past an edge back.
    /// It is carried through from the saved origin rather than read from the
    /// panel, which may stand where a restore or the system moved it. With
    /// nothing saved, nothing is saved: the default position follows the
    /// size.
    ///
    /// A live panel grows where it stands, wherever that is, and is then
    /// placed by `CaptionBarPlacement.restoredOrigin` like a `show()`, so a
    /// bar parked over the Dock stays there. AppKit does not constrain a
    /// borderless non-activating panel (measured: `constrainFrameRect`
    /// returns the target unchanged), so without that a bar flush against an
    /// edge would grow past it. A `setFrame` that changes the size posts no
    /// `didMoveNotification` (measured: 0 of 36 runs), so this placement is
    /// never saved. So a bar grown at an edge and shrunk again stands where
    /// the grown one was pulled to (200 pt in for small to large and back)
    /// until the next `show()` puts it back on the saved spot.
    func apply(size: LiveCaptionsSize) {
        guard size != self.size else { return }
        let previous = self.size
        self.size = size
        state.setSize(size)
        if let saved = storedOrigin() {
            persistOrigin(Self.resizedFrame(NSRect(origin: saved, size: previous.panelSize), to: size).origin)
        }
        if let panel {
            let resized = Self.resizedFrame(panel.frame, to: size).origin
            let origin = CaptionBarPlacement.restoredOrigin(resized, size: size, screens: Self.attachedScreens())
                ?? defaultBottomCentreOrigin()
            place(panel, at: origin)
        }
    }

    /// The frame a panel at `frame` takes when switched to `size`: same
    /// bottom edge, same horizontal centre. Anchoring the bottom-left corner
    /// instead would walk the bar sideways on every preset change, since the
    /// user parks it by eye at the bottom-centre of a call window. Not
    /// clamped to any screen.
    static func resizedFrame(_ frame: NSRect, to size: LiveCaptionsSize) -> NSRect {
        NSRect(
            x: frame.midX - size.panelSize.width / 2,
            y: frame.minY,
            width: size.panelSize.width,
            height: size.panelSize.height,
        )
    }

    /// Hide the caption bar without destroying the panel — re-showing is
    /// cheap and the underlying SwiftUI host stays bound to the same state.
    func hide() {
        dragSession.reset()
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
        panel.identifier = Self.panelIdentifier
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
        installMouseMonitor(for: panel)
        installMoveObserver(for: panel)
        return panel
    }

    /// Position the panel where it was saved (see
    /// `CaptionBarPlacement.restoredOrigin`), or bottom-centre of the main
    /// screen if nothing was saved or no attached screen overlaps the saved
    /// bar (the monitor it lived on is gone). Runs on every `show()`, since
    /// the panel is reused across recordings. The move this `setFrame` posts
    /// is not saved (see `place`).
    private func positionAtSavedOrDefault(_ panel: NSPanel) {
        let saved = storedOrigin().flatMap { stored in
            CaptionBarPlacement.restoredOrigin(stored, size: size, screens: Self.attachedScreens())
        }
        place(panel, at: saved ?? defaultBottomCentreOrigin())
    }

    /// The controller's own `setFrame`, which the move observer never saves.
    private func place(_ panel: NSPanel, at origin: CGPoint) {
        isPlacing = true
        defer { isPlacing = false }
        panel.setFrame(NSRect(origin: origin, size: size.panelSize), display: true)
    }

    private static func attachedScreens() -> [CaptionScreen] {
        NSScreen.screens.map { CaptionScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
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

    private func persistOrigin(_ origin: CGPoint) {
        defaults.set(
            ["x": origin.x, "y": origin.y],
            forKey: Self.originDefaultsKey,
        )
    }

    /// Watch ⌥ (Option). While held, flip the panel into drag-friendly mode;
    /// release returns it to click-through. Option decides only that; which
    /// moves are saved is `CaptionDragSession`'s decision. Uses both local + global
    /// monitors so the key works whether or not our app is frontmost. The
    /// NSEvent callbacks are not @MainActor-isolated, so each hop onto the
    /// main actor before touching the panel.
    private func installModifierMonitor(for panel: NSPanel) {
        guard globalModifierMonitor == nil else { return }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged,
        ) { [weak self, weak panel] event in
            let flags = event.modifierFlags
            Task { @MainActor in
                guard let self, let panel else { return }
                self.applyModifierState(to: panel, flags: flags)
            }
        }
        // Local monitor mirrors the same logic for when our app is frontmost.
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(
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

    /// Feeds the left button's down and up on the panel to `dragSession`. In
    /// drag mode the panel accepts mouse events, and a local monitor sees the
    /// down and up of every drag on it (measured). Only a down on the panel
    /// starts a session; an up without one is ignored by the session.
    private func installMouseMonitor(for panel: NSPanel) {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp],
        ) { [weak self, weak panel] event in
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                if event.type == .leftMouseDown {
                    if event.window === panel { self.dragSession.mouseDown() }
                } else {
                    self.dragSession.mouseUp(at: self.now())
                }
            }
            return event
        }
    }

    /// Saves the panel's origin when `dragSession` says the move is the
    /// user's drag; not the `setFrame` of a `show()` or a preset change, and
    /// not the system relocating the panel when a display goes away.
    ///
    /// AppKit posts the notification on the main thread from inside the call
    /// that moved the panel, and a `.main` queue observer runs synchronously
    /// there (measured), so each move is judged at the time it was made.
    /// Mouse-up and move times are both taken when the main thread handles
    /// them, so a stall delays them together; the up's own event timestamp
    /// would only pull the settle deadline earlier.
    private func installMoveObserver(for panel: NSPanel) {
        guard moveObserver == nil else { return }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main,
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel, !self.isPlacing,
                      self.dragSession.shouldSaveMove(
                          at: self.now(),
                          buttonPressed: self.buttonPressed(),
                      )
                else { return }
                self.persistOrigin(panel.frame.origin)
            }
        }
    }
}
