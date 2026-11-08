import AppKit
@testable import MeetingTranscriber
import XCTest

/// The controller with a real panel: which moves are saved (only the user's
/// drag, see `CaptionDragSession`) and where a preset change leaves the
/// panel and the saved origin. The controller places against `screen`, an
/// injected geometry, not the host's displays: a second display next to the
/// main one makes a bar past its edge reachable, so the expected clamps
/// would change with the machine. The panel itself is still real, so
/// `screen` is drawn inside the real main display (see `screenInside`) and
/// the tests are skipped on a runner without one.
@MainActor
final class LiveCaptionsPanelSavingTests: XCTestCase {
    /// The left button and the clock the controller reads. Events injected
    /// with `sendEvent` change neither the real button state nor the time,
    /// so `send` sets the button and tests advance the clock.
    private final class FakeMouse {
        var pressed = false
        var time: TimeInterval = 1000
        var location = CGPoint.zero
    }

    private let mouse = FakeMouse()

    /// The one screen the controller sees, set up per test.
    private var screen = CaptionScreen(frame: .zero, visibleFrame: .zero)
    private var visible: CGRect {
        screen.visibleFrame
    }

    override func setUp() async throws {
        try await super.setUp()
        screen = try Self.screenInside((NSScreen.main ?? NSScreen.screens.first)?.frame)
    }

    override func tearDown() async throws {
        screen = CaptionScreen(frame: .zero, visibleFrame: .zero)
        try await super.tearDown()
    }

    /// `display` inset by 8 pt, with a 25 pt menu bar and a 70 pt Dock at
    /// the bottom synthesised inside it. Every panel position the tests
    /// expect then lies on a real display, where AppKit's handling of the
    /// panel (no constraining, flooring to whole points, move
    /// notifications) was measured, while the expected values still come
    /// from this geometry alone. The inset also keeps the frame off the
    /// origin, so a coordinate that ignores `minX`/`minY` cannot pass by
    /// accident, and the Dock strip makes the parked-over-the-Dock case tell
    /// its two placements apart on any host.
    private static func screenInside(_ display: CGRect?) throws -> CaptionScreen {
        guard let display else { throw XCTSkip("no screen to show the panel on") }
        // Whole points and an even width, so `midX` and every origin derived
        // from it is a whole point that AppKit leaves where it is put. The
        // inset is small because CI's virtual display is not much larger than
        // what the tests need, and a skipped class there tests nothing.
        let inset = display.insetBy(dx: 8, dy: 8).integral
        let frame = CGRect(
            x: inset.minX, y: inset.minY,
            width: (inset.width / 2).rounded(.down) * 2, height: inset.height,
        )
        // The tests move a large (920 pt) bar and lift one 300 pt off the
        // bottom of the visible frame, which needs about this much room.
        guard frame.width >= 960, frame.height >= 600 else {
            throw XCTSkip("main screen \(display.size) too small for the panel tests (960x600 pt after the inset)")
        }
        let menuBar: CGFloat = 25
        let dock: CGFloat = 70
        return CaptionScreen(
            frame: frame,
            visibleFrame: CGRect(
                x: frame.minX, y: frame.minY + dock,
                width: frame.width, height: frame.height - dock - menuBar,
            ),
        )
    }

    /// A small-preset controller on a throwaway defaults suite, with `saved`
    /// as the saved origin when given.
    private func makeController(saved: CGPoint? = nil) throws -> (LiveCaptionsWindowController, UserDefaults) {
        let name = "captions-panel-\(getpid())-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(name))
        addTeardownBlock { DefaultsSuite.remove(name) }
        if let saved {
            defaults.set(["x": saved.x, "y": saved.y], forKey: LiveCaptionsWindowController.originDefaultsKey)
        }
        let mouse = mouse
        let screen = screen
        let controller = LiveCaptionsWindowController(
            state: LiveCaptionsState(), size: .small, defaults: defaults,
            buttonPressed: { mouse.pressed }, now: { mouse.time }, mouseLocation: { mouse.location },
            screens: { [screen] }, mainScreen: { screen },
        )
        return (controller, defaults)
    }

    /// The saved origin, or nil when nothing is saved.
    private func stored(in defaults: UserDefaults) -> CGPoint? {
        guard let dict = defaults.dictionary(forKey: LiveCaptionsWindowController.originDefaultsKey),
              let x = dict["x"] as? Double, let y = dict["y"] as? Double
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Shows the bar and returns the panel the controller made for it: the
    /// caption window that was not there before. At the end of the test the
    /// bar is hidden and the controller must be gone, which is what removes
    /// its key monitors and move observer.
    private func showPanel(_ controller: LiveCaptionsWindowController) throws -> NSWindow {
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        controller.show()
        addTeardownBlock { @MainActor [weak controller] in
            controller?.hide()
            XCTAssertNil(controller, "the controller outlived its test")
        }
        return try XCTUnwrap(NSApplication.shared.windows.first { window in
            !before.contains(ObjectIdentifier(window)) && window.identifier == LiveCaptionsWindowController.panelIdentifier
        })
    }

    /// Sends a left mouse button event to `panel` through the application,
    /// which is where the controller's local monitor sees it.
    private func send(_ type: NSEvent.EventType, to panel: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        ))
        mouse.pressed = type == .leftMouseDown || type == .leftMouseDragged
        NSApplication.shared.sendEvent(event)
    }

    /// Moves the panel the way a user's drag does: button down on the panel,
    /// the move, button up. The move observer runs inside `setFrameOrigin`,
    /// so no wait is needed.
    private func drag(_ panel: NSWindow, to origin: CGPoint) throws {
        try send(.leftMouseDown, to: panel)
        panel.setFrameOrigin(origin)
        try send(.leftMouseUp, to: panel)
    }

    func testOptionDragEventsMoveAndSaveThePanelUntilMouseUp() throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let start = panel.frame.origin
        panel.ignoresMouseEvents = false

        mouse.location = CGPoint(x: 300, y: 250)
        try send(.leftMouseDown, to: panel)
        mouse.location = CGPoint(x: 335, y: 230)
        try send(.leftMouseDragged, to: panel)

        let moved = CGPoint(x: start.x + 35, y: start.y - 20)
        XCTAssertEqual(panel.frame.origin, moved)
        XCTAssertEqual(stored(in: defaults), moved)

        try send(.leftMouseUp, to: panel)
        mouse.location = CGPoint(x: 400, y: 250)
        try send(.leftMouseDragged, to: panel)
        XCTAssertEqual(panel.frame.origin, moved)
    }

    /// A move with no drag of the user's behind it, such as the system
    /// relocating the panel when a display is unplugged or reconfigured,
    /// leaves the saved position alone; a drag is saved.
    func testOnlyAMoveDuringADragIsSaved() throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)

        panel.setFrameOrigin(CGPoint(x: visible.minX + 120, y: visible.minY + 70))
        XCTAssertNil(stored(in: defaults), "a move with no drag was saved")

        let dragged = CGPoint(x: visible.minX + 160, y: visible.minY + 90)
        try drag(panel, to: dragged)
        XCTAssertEqual(stored(in: defaults), dragged, "a drag was not saved")
    }

    /// Holding Option does not make a move the user's: the restore's own
    /// `setFrame` while drag mode is on is not saved.
    func testAPlacementInDragModeWithoutADragIsNotSaved() throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        panel.setFrameOrigin(CGPoint(x: visible.minX + 120, y: visible.minY + 70))

        panel.isMovableByWindowBackground = true
        controller.show()
        panel.isMovableByWindowBackground = false

        XCTAssertNil(stored(in: defaults), "the restore's move was saved")
    }

    /// Releasing Option mid-drag turns drag mode off, but the panel keeps
    /// following the mouse while the button is down (measured: one drag ran
    /// on some 600 pt), so those moves are saved too.
    func testMovesAfterOptionIsReleasedMidDragAreSaved() throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)

        try send(.leftMouseDown, to: panel)
        panel.isMovableByWindowBackground = true
        panel.setFrameOrigin(CGPoint(x: visible.minX + 120, y: visible.minY + 70))
        panel.isMovableByWindowBackground = false
        let rest = CGPoint(x: visible.minX + 400, y: visible.minY + 90)
        panel.setFrameOrigin(rest)
        try send(.leftMouseUp, to: panel)

        XCTAssertEqual(stored(in: defaults), rest)
    }

    /// A drag held longer than the settle window, with the button down the
    /// whole time, is saved to its end: while the button is physically down
    /// the session stays open whatever the clock says.
    func testAHeldDragLongerThanTheSettleWindowIsSavedToItsEnd() throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)

        try send(.leftMouseDown, to: panel)
        panel.setFrameOrigin(CGPoint(x: visible.minX + 120, y: visible.minY + 70))
        mouse.time += 10 * CaptionDragSession.settleWindow
        let rest = CGPoint(x: visible.minX + 400, y: visible.minY + 90)
        panel.setFrameOrigin(rest)

        XCTAssertEqual(stored(in: defaults), rest)
    }

    /// A recording that ends mid-drag orders the panel out, and the mouse-up
    /// may then go elsewhere. A later move by anything else, even with the
    /// button still held, is not taken for that drag.
    func testADragCutOffByHideSavesNoLaterMove() throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        try send(.leftMouseDown, to: panel)

        controller.hide()
        panel.setFrameOrigin(CGPoint(x: visible.minX + 120, y: visible.minY + 70))

        XCTAssertNil(stored(in: defaults), "a move after hide() was taken for the cut-off drag")
    }

    /// The same for `show()` while the panel is still up (a second show with
    /// no hide between): it starts without the drag that was open.
    func testShowingAgainMidDragSavesNoLaterMove() throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        try send(.leftMouseDown, to: panel)

        controller.show()
        panel.setFrameOrigin(CGPoint(x: visible.minX + 120, y: visible.minY + 70))

        XCTAssertNil(stored(in: defaults), "a move after show() was taken for the open drag")
    }

    /// The controller's own placement is never saved, also in the middle of
    /// a drag: a preset change while the button is down saves only the
    /// re-centred saved origin, never where the live panel was placed.
    func testAPresetChangeDuringADragDoesNotSaveTheLivePlacement() throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        try send(.leftMouseDown, to: panel)
        let parked = CGPoint(x: visible.maxX - LiveCaptionsSize.small.panelSize.width, y: visible.minY + 60)
        panel.setFrameOrigin(parked)

        controller.apply(size: .large)
        try send(.leftMouseUp, to: panel)

        let recentred = LiveCaptionsWindowController.resizedFrame(
            NSRect(origin: parked, size: LiveCaptionsSize.small.panelSize), to: .large,
        ).origin
        XCTAssertNotEqual(panel.frame.origin, recentred, "fixture: the live placement did not move the bar")
        XCTAssertEqual(stored(in: defaults), recentred)
    }

    /// After mouse-up the panel keeps sliding (measured: 200 to 400 ms, often
    /// to a screen edge); where it comes to rest is saved.
    func testTheSlideAfterMouseUpIsSaved() throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)

        try drag(panel, to: CGPoint(x: visible.minX + 120, y: visible.minY + 70))
        let rest = CGPoint(x: visible.minX, y: visible.minY + 70)
        panel.setFrameOrigin(rest)

        XCTAssertEqual(stored(in: defaults), rest)
    }

    /// Parked by the user with its bottom over the Dock strip (flush with the
    /// bottom of the screen's full frame). A preset change keeps it there:
    /// the saved origin is the parked one re-centred for the new width, and
    /// the live panel stands at that same origin, not pushed up into the
    /// visible frame. The injected screen has its Dock at the bottom, so the
    /// two are told apart.
    func testABarParkedOverTheDockKeepsItsPositionAcrossAPresetChange() throws {
        let frame = screen.frame
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        try drag(panel, to: CGPoint(x: frame.midX - 260, y: frame.minY))

        controller.apply(size: .large)

        let expected = CGPoint(x: frame.midX - 460, y: frame.minY)
        XCTAssertEqual(stored(in: defaults), expected)
        XCTAssertEqual(panel.frame.origin, expected)
    }

    /// AppKit floors a panel's origin to whole points (measured: 100.3 and
    /// 100.25 both land on 100, -400.2 on -401, on a 2x display). Showing a
    /// bar saved at a fractional origin must not save the floored one: that
    /// is the restore's own `setFrame`, not a move by the user, and saving it
    /// shifts the saved position by up to a point on every such restore.
    ///
    /// The control drags the panel afterwards: that move must be saved, so a
    /// move notification that never reached the observer cannot make the
    /// first assertion pass.
    func testShowingTheBarDoesNotSaveWhereAppKitPutIt() throws {
        let saved = CGPoint(x: visible.minX + 100.3, y: visible.minY + 60.7)
        let (controller, defaults) = try makeController(saved: saved)

        let panel = try showPanel(controller)
        XCTAssertEqual(stored(in: defaults), saved)

        let moved = CGPoint(x: visible.minX + 140, y: visible.minY + 90)
        try drag(panel, to: moved)
        XCTAssertEqual(stored(in: defaults), moved, "control: a drag-mode move is saved")
    }

    /// A preset change while the bar is still where the restore moved it
    /// carries the saved origin through the resize, exactly as a preset
    /// change without a panel does, rather than saving the restore's move.
    /// Saved 200 pt past the right edge; shown, the bar is pulled inside; the
    /// preset change saves the grown bar relative to the saved origin, and
    /// the live panel is pulled inside again.
    func testAPresetChangeAfterARestoreMoveDoesNotSaveTheMove() throws {
        let small = LiveCaptionsSize.small.panelSize
        let saved = CGPoint(x: visible.maxX - small.width + 200, y: visible.minY + 60)
        let (controller, defaults) = try makeController(saved: saved)

        let panel = try showPanel(controller)
        XCTAssertEqual(panel.frame.origin.x, visible.maxX - small.width, "fixture: the restore did not move the bar")

        controller.apply(size: .large)

        let expected = LiveCaptionsWindowController.resizedFrame(NSRect(origin: saved, size: small), to: .large).origin
        XCTAssertEqual(stored(in: defaults), expected)
        XCTAssertEqual(panel.frame.origin.x, visible.maxX - LiveCaptionsSize.large.panelSize.width)
    }

    /// A panel moved outside drag mode (by the system, say, when a display
    /// goes away) is not saved, and a preset change during the recording
    /// grows it where it now stands instead of making it jump back to the
    /// saved position. The saved origin is still re-centred for the next
    /// `show()`.
    func testAPresetChangeGrowsAPanelMovedWithoutADragWhereItStands() throws {
        let saved = CGPoint(x: visible.minX + 100, y: visible.minY + 60)
        let (controller, defaults) = try makeController(saved: saved)
        let panel = try showPanel(controller)
        let moved = CGPoint(x: visible.midX - 260, y: visible.minY + 300)
        panel.setFrameOrigin(moved)

        controller.apply(size: .large)

        XCTAssertEqual(panel.frame.origin, CGPoint(x: moved.x - 200, y: moved.y), "the panel jumped")
        XCTAssertEqual(stored(in: defaults), CGPoint(x: saved.x - 200, y: saved.y))
    }

    /// A bar the user never moved stands at the default position, which
    /// follows the size; a preset change with a live panel saves nothing, so
    /// it keeps following it.
    func testAPresetChangeOfAPanelNeverMovedSavesNothing() throws {
        let (controller, defaults) = try makeController()
        _ = try showPanel(controller)

        controller.apply(size: .large)

        XCTAssertNil(stored(in: defaults))
    }

    /// Once the user has dragged the bar flush right, a preset change saves
    /// that origin re-centred and unclamped, so the next `show()` decides
    /// from where the user put it, and the live panel is pulled back inside
    /// the screen rather than growing past its edge.
    func testAPresetChangeAfterAUserMoveSavesTheRecentredOriginAndKeepsThePanelOnScreen() throws {
        let small = LiveCaptionsSize.small.panelSize
        let large = LiveCaptionsSize.large.panelSize
        let (controller, defaults) = try makeController()

        let panel = try showPanel(controller)
        try drag(panel, to: CGPoint(x: visible.maxX - small.width, y: visible.minY + 60))

        controller.apply(size: .large)

        let recentred = CGPoint(x: visible.maxX - small.width / 2 - large.width / 2, y: visible.minY + 60)
        XCTAssertEqual(stored(in: defaults), recentred)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: visible.maxX - large.width, y: visible.minY + 60))
    }
}
