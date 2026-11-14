// One class so every case shares the panel, screen and event helpers,
// which the test-case accessibility rule keeps private.
// swiftlint:disable file_length
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
final class LiveCaptionsPanelSavingTests: XCTestCase { // swiftlint:disable:this type_body_length
    /// Injected events do not change the physical mouse state.
    private final class FakeMouse {
        var pressed = false
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
        // Read at each call, so a test can change the screen between events.
        let controller = LiveCaptionsWindowController(
            state: LiveCaptionsState(), size: .small, defaults: defaults,
            buttonPressed: { mouse.pressed }, mouseLocation: { mouse.location },
            screens: { [weak self] in self.map { [$0.screen] } ?? [] },
            mainScreen: { [weak self] in self?.screen },
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
    /// its key monitors and move observer. The teardown orders the panel out
    /// itself, since a shown panel stays on screen after its controller is
    /// released.
    private func showPanel(_ controller: LiveCaptionsWindowController) throws -> NSWindow {
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        controller.show()
        let panel = NSApplication.shared.windows.first { window in
            !before.contains(ObjectIdentifier(window)) && window.identifier == LiveCaptionsWindowController.panelIdentifier
        }
        addTeardownBlock { @MainActor [weak controller] in
            panel?.orderOut(nil)
            XCTAssertNil(controller, "the controller outlived its test")
        }
        return try XCTUnwrap(panel)
    }

    /// Sends a left mouse button event to `panel` through the application,
    /// which is where the controller's local monitor sees it.
    private func send(_ type: NSEvent.EventType, to panel: NSWindow) throws {
        try send(type, to: panel, buttonPressed: type == .leftMouseDown || type == .leftMouseDragged)
    }

    private func send(_ type: NSEvent.EventType, to panel: NSWindow, buttonPressed: Bool) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        ))
        mouse.pressed = buttonPressed
        NSApplication.shared.sendEvent(event)
    }

    private func setOption(_ held: Bool, on panel: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: held ? .option : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58,
        ))
        NSApplication.shared.sendEvent(event)
        for _ in 0 ..< 100 {
            if panel.ignoresMouseEvents == !held { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(panel.ignoresMouseEvents, !held)
    }

    /// Moves the panel the way a user's drag does: button down on the panel,
    /// the move, button up. The move observer runs inside `setFrameOrigin`,
    /// so no wait is needed.
    private func drag(_ panel: NSWindow, to origin: CGPoint) throws {
        try send(.leftMouseDown, to: panel)
        panel.setFrameOrigin(origin)
        try send(.leftMouseUp, to: panel)
    }

    func testOptionDragEventsMoveAndSaveThePanelUntilMouseUp() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let start = panel.frame.origin
        try await setOption(true, on: panel)

        mouse.location = CGPoint(x: 300, y: 250)
        try send(.leftMouseDown, to: panel)
        mouse.location = CGPoint(x: 335, y: 230)
        try send(.leftMouseDragged, to: panel)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: start.x + 35, y: start.y - 20))

        mouse.location = CGPoint(x: 350, y: 240)
        try send(.leftMouseDragged, to: panel)
        let moved = CGPoint(x: start.x + 50, y: start.y - 10)
        XCTAssertEqual(panel.frame.origin, moved)
        XCTAssertEqual(stored(in: defaults), moved)

        try send(.leftMouseUp, to: panel)
        mouse.location = CGPoint(x: 400, y: 250)
        try send(.leftMouseDragged, to: panel)
        XCTAssertEqual(panel.frame.origin, moved)
    }

    func testDraggedEventsClampAndSaveThePanelInsideTheVisibleFrame() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        try await setOption(true, on: panel)
        mouse.location = panel.frame.origin
        try send(.leftMouseDown, to: panel)

        mouse.location = CGPoint(x: visible.maxX - 10, y: screen.frame.minY)
        try send(.leftMouseDragged, to: panel)

        let expected = CGPoint(x: visible.maxX - panel.frame.width, y: visible.minY)
        XCTAssertEqual(panel.frame.origin, expected)
        XCTAssertEqual(stored(in: defaults), expected)
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

    func testAPlacementInDragModeWithoutADragIsNotSaved() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        try await setOption(true, on: panel)
        let placed = panel.frame.origin
        let relocated = CGPoint(x: placed.x + 30, y: placed.y + 20)
        panel.setFrameOrigin(relocated)

        mouse.location = CGPoint(x: 120, y: 70)
        try send(.leftMouseDragged, to: panel)
        XCTAssertEqual(panel.frame.origin, relocated)
        controller.show()

        XCTAssertEqual(panel.frame.origin, placed)
        XCTAssertNil(stored(in: defaults))
    }

    func testMovesAfterOptionIsReleasedMidDragAreSaved() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let start = panel.frame.origin
        try await setOption(true, on: panel)
        mouse.location = CGPoint(x: 300, y: 250)
        try send(.leftMouseDown, to: panel)
        mouse.location = CGPoint(x: 320, y: 260)
        try send(.leftMouseDragged, to: panel)

        try await setOption(false, on: panel)
        XCTAssertTrue(panel.ignoresMouseEvents)
        mouse.location = CGPoint(x: 350, y: 270)
        try send(.leftMouseDragged, to: panel)
        try send(.leftMouseUp, to: panel)

        let rest = CGPoint(x: start.x + 50, y: start.y + 20)
        XCTAssertEqual(panel.frame.origin, rest)
        XCTAssertEqual(stored(in: defaults), rest)
    }

    func testADragCutOffByHideSavesNoLaterMove() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        try await setOption(true, on: panel)
        mouse.location = panel.frame.origin
        try send(.leftMouseDown, to: panel)
        let start = panel.frame.origin

        controller.hide()
        mouse.location = CGPoint(x: start.x + 30, y: start.y + 20)
        try send(.leftMouseDragged, to: panel)

        XCTAssertEqual(panel.frame.origin, start)
        XCTAssertNil(stored(in: defaults))
        controller.show()
        try send(.leftMouseDragged, to: panel)
        XCTAssertEqual(panel.frame.origin, start)
        XCTAssertNil(stored(in: defaults))
    }

    func testShowingAgainMidDragSavesNoLaterMove() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        try await setOption(true, on: panel)
        mouse.location = panel.frame.origin
        try send(.leftMouseDown, to: panel)
        let start = panel.frame.origin

        controller.show()
        mouse.location = CGPoint(x: start.x + 30, y: start.y + 20)
        try send(.leftMouseDragged, to: panel)

        XCTAssertEqual(panel.frame.origin, start)
        XCTAssertNil(stored(in: defaults))
    }

    func testAMouseDownInAnotherWindowCancelsTheDrag() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        try await setOption(true, on: panel)
        mouse.location = panel.frame.origin
        try send(.leftMouseDown, to: panel)
        let start = panel.frame.origin
        let other = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false,
        )
        defer { other.orderOut(nil) }

        try send(.leftMouseDown, to: other)
        mouse.location = CGPoint(x: start.x + 30, y: start.y + 20)
        try send(.leftMouseDragged, to: other)

        XCTAssertEqual(panel.frame.origin, start)
        XCTAssertNil(stored(in: defaults))
        panel.setFrameOrigin(CGPoint(x: start.x + 40, y: start.y + 20))
        XCTAssertNil(stored(in: defaults))
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

    /// The system's relocation of a bar dropped with the pointer on a screen
    /// edge is neither saved nor left standing.
    func testAMoveAfterMouseUpIsNotSavedAndIsUndone() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let dragged = try await optionDrag(panel, to: CGPoint(x: visible.minX + 120, y: visible.minY + 70))

        panel.setFrameOrigin(CGPoint(x: visible.midX - 260, y: visible.minY + 300))

        XCTAssertEqual(stored(in: defaults), dragged)
        XCTAssertEqual(panel.frame.origin, dragged)
    }

    /// The same relocation handled before the drag's mouse-up, as it was in
    /// most live runs on macOS 27.2: the button is already up when the move
    /// arrives, and the frame the mouse-up then finds is the system's. The
    /// drop is where the drag last put the panel, so the panel goes back there,
    /// and a further move in the window is undone to it too, not to the jump.
    func testAMoveHandledBeforeMouseUpIsUndoneToTheDrop() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let dragged = try await optionPressAndDrag(panel, to: CGPoint(x: visible.minX + 120, y: visible.minY + 70))

        mouse.pressed = false
        panel.setFrameOrigin(CGPoint(x: visible.midX - 260, y: visible.minY + 300))
        try send(.leftMouseUp, to: panel, buttonPressed: false)

        XCTAssertEqual(panel.frame.origin, dragged)
        panel.setFrameOrigin(CGPoint(x: visible.minX + 400, y: visible.minY + 200))
        XCTAssertEqual(panel.frame.origin, dragged)
        XCTAssertEqual(stored(in: defaults), dragged)
    }

    /// The relocation handled while the button still reads down is saved as
    /// the drag's own move; the mouse-up then puts back both the panel and
    /// the saved origin, so the next `show()` does not open at the jump.
    func testAMoveSavedBeforeMouseUpIsUndoneAndUnsaved() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let dragged = try await optionPressAndDrag(panel, to: CGPoint(x: visible.minX + 120, y: visible.minY + 70))

        let jumped = CGPoint(x: visible.midX - 260, y: visible.minY + 300)
        panel.setFrameOrigin(jumped)
        XCTAssertEqual(stored(in: defaults), jumped, "fixture: the move was not taken as the drag's")
        try send(.leftMouseUp, to: panel, buttonPressed: false)

        XCTAssertEqual(panel.frame.origin, dragged)
        XCTAssertEqual(stored(in: defaults), dragged)
    }

    /// A visible frame that shrank between the last dragged event and the
    /// mouse-up (a display change, say) is no system move: the mouse-up
    /// neither moves the bar nor saves anything over the drop.
    func testAVisibleFrameThatShrankBeforeMouseUpLeavesTheDrop() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let topFlush = CGPoint(x: visible.minX + 100, y: visible.maxY - panel.frame.height)
        let dragged = try await optionPressAndDrag(panel, to: topFlush)

        shrinkVisibleFrameFromTop(by: 25)
        try send(.leftMouseUp, to: panel, buttonPressed: false)

        XCTAssertEqual(panel.frame.origin, dragged)
        XCTAssertEqual(stored(in: defaults), dragged)
    }

    /// A system move inside the relocation window while the visible frame is
    /// smaller puts the bar back inside it, but the user's drop stays saved,
    /// so the next `show()` returns to it once the display is back.
    func testUndoingInsideAShrunkVisibleFrameKeepsTheDropSaved() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let topFlush = CGPoint(x: visible.minX + 100, y: visible.maxY - panel.frame.height)
        let dragged = try await optionDrag(panel, to: topFlush)

        shrinkVisibleFrameFromTop(by: 25)
        panel.setFrameOrigin(CGPoint(x: visible.midX - 260, y: visible.minY + 100))

        XCTAssertEqual(panel.frame.origin, CGPoint(x: dragged.x, y: dragged.y - 25))
        XCTAssertEqual(stored(in: defaults), dragged)
    }

    /// A preset change during an Option-drag ends the drag: later dragged
    /// events no longer move the bar, a move with the button still down is
    /// not saved as the user's, and the mouse-up leaves the re-centred bar.
    func testAPresetChangeDuringAnOptionDragEndsTheDrag() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        _ = try await optionPressAndDrag(panel, to: CGPoint(x: visible.minX + 120, y: visible.minY + 70))
        controller.apply(size: .large)
        let placed = panel.frame.origin
        let saved = stored(in: defaults)

        mouse.location = CGPoint(x: mouse.location.x + 40, y: mouse.location.y + 10)
        try send(.leftMouseDragged, to: panel)
        XCTAssertEqual(panel.frame.origin, placed)
        panel.setFrameOrigin(CGPoint(x: placed.x + 30, y: placed.y + 20))
        XCTAssertEqual(stored(in: defaults), saved)
        try send(.leftMouseUp, to: panel)
        XCTAssertEqual(stored(in: defaults), saved)
    }

    /// Lowers the top of the injected screen's visible frame, as a menu bar
    /// or a display change would.
    private func shrinkVisibleFrameFromTop(by points: CGFloat) {
        var shrunk = screen.visibleFrame
        shrunk.size.height -= points
        screen = CaptionScreen(frame: screen.frame, visibleFrame: shrunk)
    }

    /// An Option-click that never moves the panel is no drop: a move before
    /// its mouse-up stands.
    func testAnOptionClickWithoutADragHoldsNoDrop() async throws {
        let (controller, _) = try makeController()
        let panel = try showPanel(controller)
        try await setOption(true, on: panel)
        mouse.location = panel.frame.origin
        try send(.leftMouseDown, to: panel)

        let moved = CGPoint(x: visible.midX - 260, y: visible.minY + 300)
        mouse.pressed = false
        panel.setFrameOrigin(moved)
        try send(.leftMouseUp, to: panel, buttonPressed: false)

        XCTAssertEqual(panel.frame.origin, moved)
    }

    /// Past `dropRelocationWindow`, a move by the system (a display going
    /// away, say) stands, as it does without a drag.
    func testAMoveLongAfterMouseUpStands() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let dragged = try await optionDrag(panel, to: CGPoint(x: visible.minX + 120, y: visible.minY + 70))

        try await Task.sleep(for: .seconds(LiveCaptionsWindowController.dropRelocationWindow + 0.2))
        let relocated = CGPoint(x: visible.midX - 260, y: visible.minY + 300)
        panel.setFrameOrigin(relocated)

        XCTAssertEqual(stored(in: defaults), dragged)
        XCTAssertEqual(panel.frame.origin, relocated)
    }

    /// A dragged event handled after the button is already up, as one queued
    /// behind a main-thread stall is, does not move the panel either, so
    /// what stands and what is saved stay the same.
    func testADraggedEventWithTheButtonUpDoesNotMoveThePanel() async throws {
        let (controller, defaults) = try makeController()
        let panel = try showPanel(controller)
        let start = panel.frame.origin
        try await setOption(true, on: panel)
        mouse.location = start
        try send(.leftMouseDown, to: panel)

        mouse.location = CGPoint(x: start.x + 30, y: start.y + 20)
        try send(.leftMouseDragged, to: panel, buttonPressed: false)

        XCTAssertEqual(panel.frame.origin, start)
        XCTAssertNil(stored(in: defaults))
    }

    /// Option-drags the panel so its origin lands on `origin`, then releases.
    private func optionDrag(_ panel: NSWindow, to origin: CGPoint) async throws -> CGPoint {
        let dragged = try await optionPressAndDrag(panel, to: origin)
        try send(.leftMouseUp, to: panel)
        XCTAssertEqual(panel.frame.origin, origin, "fixture: the drop moved the panel")
        return dragged
    }

    /// Presses on the panel in Option mode and drags its origin onto
    /// `origin`, leaving the button down.
    private func optionPressAndDrag(_ panel: NSWindow, to origin: CGPoint) async throws -> CGPoint {
        try await setOption(true, on: panel)
        mouse.location = panel.frame.origin
        try send(.leftMouseDown, to: panel)
        mouse.location = origin
        try send(.leftMouseDragged, to: panel)
        XCTAssertEqual(panel.frame.origin, origin, "fixture: the drag did not land")
        return origin
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
