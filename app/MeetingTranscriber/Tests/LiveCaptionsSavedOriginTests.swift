import AppKit
@testable import MeetingTranscriber
import XCTest

/// Where the caption bar is placed on every `show()` and on a preset change.
/// What a real panel saves is in `LiveCaptionsPanelSavingTests`.
@MainActor
final class LiveCaptionsSavedOriginTests: XCTestCase {
    /// The visible frame the defect was measured on.
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 900)

    /// `screen` as the only attached screen.
    private var single: [CaptionScreen] {
        [plain(screen)]
    }

    /// A screen right of `screen`, taller than it.
    private let secondary = CaptionScreen(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
    )

    /// A screen with the Dock at the bottom, taking an 80 pt strip.
    private let withDock = CaptionScreen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 870),
    )

    /// The primary screen with the Dock on the side, so its visible frame
    /// reaches down to the frame's bottom edge.
    private let primaryDockOnSide = CaptionScreen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 70, y: 0, width: 1442, height: 949),
    )

    /// Allowed ulp overshoot of `maxX - width + width` in `assertRestored`; not the placement's own edge tolerance.
    private let slack: CGFloat = 0.001

    /// A small-preset controller on a throwaway defaults suite, with `saved`
    /// as the saved origin when given.
    private func makeController(saved: CGPoint? = nil) throws -> (LiveCaptionsWindowController, UserDefaults) {
        let name = "captions-origin-\(getpid())-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { DefaultsSuite.remove(name) }
        if let saved {
            defaults.set(["x": saved.x, "y": saved.y], forKey: LiveCaptionsWindowController.originDefaultsKey)
        }
        return (LiveCaptionsWindowController(state: LiveCaptionsState(), size: .small, defaults: defaults), defaults)
    }

    /// A screen with no menu bar or Dock strip.
    private func plain(_ rect: CGRect) -> CaptionScreen {
        CaptionScreen(frame: rect, visibleFrame: rect)
    }

    private func restore(_ origin: CGPoint, _ size: LiveCaptionsSize, on screens: [CaptionScreen]) -> CGPoint? {
        CaptionBarPlacement.restoredOrigin(origin, size: size, screens: screens)
    }

    /// The saved origin, or nil when nothing is saved.
    private func stored(in defaults: UserDefaults) -> CGPoint? {
        guard let dict = defaults.dictionary(forKey: LiveCaptionsWindowController.originDefaultsKey),
              let x = dict["x"] as? Double, let y = dict["y"] as? Double
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The bar came back (not reset to the default), lies inside `target`'s
    /// visible frame, and restoring it again leaves it exactly where it is.
    private func assertRestored(
        _ origin: CGPoint?, size: LiveCaptionsSize, onto target: CaptionScreen, screens: [CaptionScreen],
        file: StaticString = #filePath, line: UInt = #line,
    ) {
        guard let origin else {
            XCTFail("bar reset to the default position instead of being kept on \(target)", file: file, line: line)
            return
        }
        let frame = CGRect(origin: origin, size: size.panelSize)
        let visible = target.visibleFrame
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX - slack, "left of \(visible)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX + slack, "right of \(visible)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY - slack, "below \(visible)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY + slack, "above \(visible)", file: file, line: line)
        XCTAssertEqual(restore(origin, size, on: screens), origin, "a restored bar moved on the next restore", file: file, line: line)
    }

    /// Where a bar of the small preset at `origin` stands after a change to
    /// the large one: re-centred, then placed as `show()` places it.
    private func grown(from origin: CGPoint, on screens: [CaptionScreen]) throws -> CGPoint {
        let small = NSRect(origin: origin, size: LiveCaptionsSize.small.panelSize)
        let resized = LiveCaptionsWindowController.resizedFrame(small, to: .large).origin
        return try XCTUnwrap(restore(resized, .large, on: screens), "fixture: the grown bar left every screen")
    }

    // MARK: - Kept where the user left it

    /// Measured: `.small` to `.large` near the right edge clamps to x = 592,
    /// whose right edge sits exactly on `screen.maxX`.
    func testABarClampedFlushRightComesBackUnchanged() throws {
        let origin = try grown(from: CGPoint(x: 900, y: 60), on: single)
        XCTAssertEqual(origin, CGPoint(x: 592, y: 60))
        XCTAssertEqual(restore(origin, .large, on: single), origin)
    }

    func testABarClampedFlushTopComesBackUnchanged() throws {
        let origin = try grown(from: CGPoint(x: 400, y: 740), on: single)
        XCTAssertEqual(origin.y + LiveCaptionsSize.large.panelSize.height, screen.maxY)
        XCTAssertEqual(restore(origin, .large, on: single), origin)
    }

    /// Parked on purpose with its bottom over the Dock: the top edge is on
    /// the visible frame, so the bar stays there rather than being pushed up
    /// to the visible frame on every show.
    func testABarParkedPartlyOverTheDockStaysWhereItIs() {
        let origin = CGPoint(x: 300, y: 40)
        XCTAssertEqual(restore(origin, .large, on: [withDock]), origin)
    }

    /// A drag that left the bar a fraction of a point past the edge is kept
    /// as the user left it, not snapped by that fraction.
    func testABarAFractionOfAPointPastTheEdgeStaysWhereItIs() {
        let origin = CGPoint(x: 592.3, y: 60)
        XCTAssertEqual(restore(origin, .large, on: single), origin)
    }

    /// Parked on purpose across the seam of two side-by-side screens: each
    /// top corner is on one of them and the whole bar is visible, so it is
    /// reachable and stays where the user put it instead of being pushed
    /// onto one screen on every show.
    func testABarAcrossTheSeamOfTwoSideBySideScreensStaysWhereItIs() {
        let origin = CGPoint(x: 1236, y: 60)
        for screens in [[plain(screen), secondary], [secondary, plain(screen)]] {
            XCTAssertEqual(restore(origin, .large, on: screens), origin)
        }
    }

    /// Hanging below every screen but for its top 5 pt: the top corners are
    /// on the visible frame (the Dock is on the side, so it reaches the
    /// bottom edge), the bottom corners on no screen at all. Nobody can see
    /// or grab 5 pt of bar, so it is moved up onto the screen.
    func testABarHangingBelowEveryScreenButForAFewPointsIsMovedOnScreen() {
        let origin = CGPoint(x: 300, y: 5 - LiveCaptionsSize.large.panelSize.height)
        XCTAssertEqual(restore(origin, .large, on: [primaryDockOnSide]), CGPoint(x: 300, y: 0))
    }

    // MARK: - Moved onto a screen

    /// A preset change made in Settings before the first recording has no
    /// panel and so no screen to clamp to: growing a bar parked flush right
    /// saves an origin whose right edge is 200 pt past the screen, one parked
    /// flush left an origin below `minX`.
    func testAPresetChangeWithoutAPanelAtAnEdgeIsPulledBackOnScreen() throws {
        for (saved, expected) in [
            (CGPoint(x: 992, y: 60), CGPoint(x: 592, y: 60)),
            (CGPoint(x: 0, y: 60), CGPoint(x: 0, y: 60)),
        ] {
            let (controller, defaults) = try makeController(saved: saved)

            controller.apply(size: .large)

            let restored = try restore(XCTUnwrap(stored(in: defaults)), .large, on: single)
            assertRestored(restored, size: .large, onto: plain(screen), screens: single)
            XCTAssertEqual(restored, expected, "saved at \(saved)")
        }
    }

    /// A secondary screen left of the main one with a fractional frame. The
    /// clamp puts the bar at `maxX - width`, and adding the width back lands
    /// one ulp past `maxX`, so an exact edge comparison rejects the origin
    /// the clamp itself produced.
    func testAFractionalNegativeEdgeThatDoesNotRoundTripKeepsTheBar() throws {
        let leftScreen = plain(CGRect(x: -2407.3, y: 0, width: 1279.3, height: 900))
        let width = LiveCaptionsSize.large.panelSize.width
        XCTAssertGreaterThan(
            (leftScreen.frame.maxX - width) + width, leftScreen.frame.maxX,
            "fixture no longer exercises the round-trip overshoot",
        )
        let screens = single + [leftScreen]
        let origin = try grown(from: CGPoint(x: leftScreen.frame.maxX - 300, y: 60), on: screens)

        assertRestored(restore(origin, .large, on: screens), size: .large, onto: leftScreen, screens: screens)
    }

    /// Saved flush against the top while the menu bar was hidden; restored
    /// with the menu bar taking its strip again. The bar moves down by the
    /// menu bar height instead of resetting.
    func testAVisibleFrameShrunkByTheMenuBarKeepsTheBar() {
        let atRestore = CaptionScreen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 920),
        )
        let origin = CGPoint(x: 300, y: 944 - LiveCaptionsSize.large.panelSize.height)

        let restored = restore(origin, .large, on: [atRestore])

        assertRestored(restored, size: .large, onto: atRestore, screens: [atRestore])
        XCTAssertEqual(restored, CGPoint(x: 300, y: 660))
    }

    /// Parked partly over a Dock on the left side. The Dock strip is inside
    /// the full frame, and only the menu bar keeps a bar out of reach, so it
    /// stays where the user put it instead of being pushed right of the
    /// Dock on every show.
    func testABarParkedPartlyOverASideDockStaysWhereItIs() {
        let leftDock = CaptionScreen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            visibleFrame: CGRect(x: 70, y: 0, width: 1442, height: 920),
        )
        let origin = CGPoint(x: 20, y: 60)
        XCTAssertEqual(restore(origin, .large, on: [leftDock]), origin)
    }

    /// A bar that overlaps only the Dock strip of a screen still belongs to
    /// that screen: the screen is chosen by its full frame, so the strip
    /// counts, and the bar is pushed into the visible frame above it.
    func testABarOverlappingOnlyTheDockStripLandsOnThatScreen() {
        let restored = restore(CGPoint(x: 300, y: -200), .large, on: [withDock])

        assertRestored(restored, size: .large, onto: withDock, screens: [withDock])
        XCTAssertEqual(restored, CGPoint(x: 300, y: 80))
    }

    /// An unreachable bar straddling two screens (hanging below both) goes
    /// onto the one it overlaps most.
    func testABarAcrossTwoScreensGoesOntoTheOneItOverlapsMost() {
        let screens = [plain(screen), secondary]
        // 920 wide, 276 on the main screen, 644 on the secondary.
        let restored = restore(CGPoint(x: 1236, y: -100), .large, on: screens)

        assertRestored(restored, size: .large, onto: secondary, screens: screens)
        XCTAssertEqual(restored, CGPoint(x: 1512, y: 0))
    }

    /// Split 460/460 (hanging below both, so it has to move): the screen
    /// holding the bar's centre wins, whichever order the screens are listed
    /// in.
    func testAnEvenSplitGoesToTheScreenHoldingTheCentreInEitherOrder() {
        let origin = CGPoint(x: 1512 - 460, y: -100)

        for screens in [[plain(screen), secondary], [secondary, plain(screen)]] {
            let restored = restore(origin, .large, on: screens)
            assertRestored(restored, size: .large, onto: secondary, screens: screens)
            XCTAssertEqual(restored, CGPoint(x: 1512, y: 0))
        }
    }

    /// Equal overlap and neither screen holding the centre: two screens that
    /// touch only at a corner, with the bar's centre on that corner. Only the
    /// primary screen's place in `NSScreen.screens` is documented, so the
    /// choice must not depend on how the others are listed.
    func testAnEvenSplitWithTheCentreOnNeitherScreenIgnoresListOrder() {
        let topLeft = plain(CGRect(x: 0, y: 1000, width: 1000, height: 1000))
        let bottomRight = plain(CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        // 920 x 260 centred on (1000, 1000): 460 x 130 on each screen.
        let origin = CGPoint(x: 540, y: 870)

        let forward = restore(origin, .large, on: [topLeft, bottomRight])
        let backward = restore(origin, .large, on: [bottomRight, topLeft])

        XCTAssertEqual(forward, backward)
        assertRestored(forward, size: .large, onto: topLeft, screens: [topLeft, bottomRight])
    }

    /// Moving along one axis leaves the other exactly as saved: no recentre
    /// through the midpoint, which does not round-trip a fractional origin.
    func testAMoveOnOneAxisKeepsTheOtherAxisExact() {
        let restored = restore(CGPoint(x: 0.1, y: 700), .large, on: single)
        XCTAssertEqual(restored, CGPoint(x: 0.1, y: 640))
    }

    // MARK: - Back to the default

    func testABarOnADisconnectedMonitorFallsBackToTheDefault() {
        XCTAssertNil(restore(CGPoint(x: 2000, y: 60), .large, on: single))
    }

    /// A bar clamped flush to the top of a screen below the primary has its
    /// top edge exactly on the primary's bottom edge; one parked flush to the
    /// bottom of a screen above sits on the primary's top edge. With that
    /// screen unplugged the whole bar is off every screen, so it goes to the
    /// default instead of being kept where nothing shows it. The top edge
    /// touching the primary's visible frame is not enough.
    func testABarOnAnUnpluggedScreenBelowOrAboveFallsBackToTheDefault() {
        for (other, origin) in [
            (plain(CGRect(x: 0, y: -1080, width: 1920, height: 1080)), CGPoint(x: 300, y: -LiveCaptionsSize.large.panelSize.height)),
            (plain(CGRect(x: 0, y: 982, width: 1920, height: 1080)), CGPoint(x: 300, y: 982)),
        ] {
            XCTAssertEqual(restore(origin, .large, on: [primaryDockOnSide, other]), origin, "\(origin)")
            XCTAssertNil(restore(origin, .large, on: [primaryDockOnSide]), "\(origin)")
        }
    }

    func testNoAttachedScreenFallsBackToTheDefault() {
        XCTAssertNil(restore(.zero, .small, on: []))
    }

    /// During a display reconfiguration a screen can briefly report a NaN or
    /// empty frame. Such a screen neither wins the lookup (a NaN rect
    /// intersects to the bar's own rect, which would score full area) nor
    /// hides a real screen.
    func testANaNScreenFrameIsIgnored() {
        let nan = CGRect(x: CGFloat.nan, y: CGFloat.nan, width: CGFloat.nan, height: CGFloat.nan)
        let broken = CaptionScreen(frame: nan, visibleFrame: nan)
        let empty = plain(.zero)

        XCTAssertNil(restore(CGPoint(x: 2000, y: 60), .large, on: [broken, empty] + single))
        XCTAssertEqual(restore(CGPoint(x: 800, y: 60), .large, on: [plain(screen), empty, broken]), CGPoint(x: 592, y: 60))
    }

    /// A saved origin that is not a finite point (a corrupt or hand-edited
    /// defaults entry) goes back to the default rather than being placed:
    /// a NaN bar intersects any screen to that screen's full frame, so it
    /// would win the lookup and be clamped to NaN.
    func testANonFiniteSavedOriginFallsBackToTheDefault() {
        for origin in [
            CGPoint(x: CGFloat.nan, y: 60),
            CGPoint(x: 300, y: CGFloat.nan),
            CGPoint(x: CGFloat.infinity, y: 60),
            CGPoint(x: 300, y: -CGFloat.infinity),
        ] {
            XCTAssertNil(restore(origin, .large, on: single), "\(origin)")
        }
    }

    // MARK: - Sweep

    /// Any origin a preset change gives a live panel at any of the four
    /// edges, on a screen offset from the global origin or with a fractional
    /// frame, comes back on that same screen, exactly where it was. The
    /// offsets keep the grown bar overlapping its screen; past that it goes
    /// to the default, which other tests cover.
    func testEveryOriginAPresetChangeProducesComesBackUnchanged() throws {
        let frames = [
            screen,
            NSRect(x: 1512, y: -180, width: 1920, height: 1055),
            NSRect(x: -2407.3, y: 37.25, width: 1279.3, height: 762.7),
        ]
        let screens = frames.map(plain)
        let small = LiveCaptionsSize.small.panelSize
        for target in screens {
            let visible = target.visibleFrame
            let corners = [
                CGPoint(x: visible.maxX - small.width, y: visible.maxY - small.height),
                CGPoint(x: visible.minX, y: visible.minY),
                CGPoint(x: visible.minX, y: visible.maxY - small.height),
                CGPoint(x: visible.maxX - small.width, y: visible.minY),
            ]
            for corner in corners {
                for dx in stride(from: -300.0, through: 300.0, by: 7.3) {
                    for dy in stride(from: -150.0, through: 150.0, by: 11.1) {
                        let origin = try grown(from: CGPoint(x: corner.x + dx, y: corner.y + dy), on: [target])
                        assertRestored(restore(origin, .large, on: screens), size: .large, onto: target, screens: screens)
                    }
                }
            }
        }
    }
}
