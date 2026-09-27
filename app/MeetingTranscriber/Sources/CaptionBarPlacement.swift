// Where the caption bar is placed each time it is shown or resized. Pure,
// over plain rects, so every case can be pinned without a display.
import AppKit

/// One attached screen as the caption bar's placement sees it: the whole
/// frame decides which screen a bar belongs to, the visible frame (without
/// menu bar and Dock) is where a bar that has to move is pushed into.
struct CaptionScreen {
    var frame: CGRect
    var visibleFrame: CGRect
}

/// The placement decision `LiveCaptionsWindowController` makes on every
/// `show()` and on every preset change of a live panel.
enum CaptionBarPlacement {
    /// How far a corner may lie outside a frame and still count as on it.
    /// Covers the ulp by which `maxX - width + width` can overshoot `maxX`
    /// on a fractional edge, which made an exact test reject origins the
    /// clamp itself had produced.
    private static let edgeTolerance: CGFloat = 0.5

    /// Where a bar of `size` at `origin` is placed, or nil for the default
    /// position.
    ///
    /// - Kept exactly where it is when it is reachable (see `isReachable`).
    /// - Otherwise moved onto the screen whose full frame it overlaps most
    ///   (see `screenOwning`), so a bar lying over that screen's menu bar or
    ///   Dock strip still belongs to it. The origin is clamped into that
    ///   screen's visible frame axis by axis, so an axis already inside is
    ///   returned exactly as given. A bar wider than the visible frame ends
    ///   flush right and overhangs on the left; only a screen narrower than
    ///   the large preset (920 pt) gets there.
    /// - Nil when no screen's frame overlaps the bar at all, which is the
    ///   "monitor disconnected" case the default position is for, and when
    ///   the origin is not a finite point.
    ///
    /// Moving instead of rejecting matters because a saved origin can
    /// legitimately be off the visible frame: a preset change saves the
    /// re-centred origin unclamped, and the visible frame at show time need
    /// not be the one at save time (menu bar auto-hide, a full-screen Space,
    /// the Dock moved). The caller does not save the move, so a visible
    /// frame that shrank for a moment costs nothing.
    ///
    /// Screens with a non-finite or empty frame, which a display
    /// reconfiguration can report briefly, are dropped before anything else:
    /// `CGRect.intersection` with a NaN rect returns the other rect, so such
    /// a screen would score the bar's full area and win, and clamping against
    /// NaN bounds leaves the origin unchanged. Plain comparisons throughout,
    /// since a `ClosedRange` over NaN bounds traps.
    static func restoredOrigin(_ origin: CGPoint, size: LiveCaptionsSize, screens: [CaptionScreen]) -> CGPoint? {
        let usable = screens.filter { isUsable($0.frame) && isUsable($0.visibleFrame) }
        let bar = CGRect(origin: origin, size: size.panelSize)
        guard bar.minX.isFinite, bar.minY.isFinite else { return nil }

        if isReachable(bar, on: usable) {
            return origin
        }
        guard let target = screenOwning(bar, among: usable) else { return nil }
        let visible = target.visibleFrame
        return CGPoint(
            x: min(max(bar.minX, visible.minX), visible.maxX - bar.width),
            y: min(max(bar.minY, visible.minY), visible.maxY - bar.height),
        )
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    /// Only the menu bar keeps a bar out of reach. Each top corner lies
    /// within some screen's full width and between its visible frame's
    /// bottom and top (so below the menu bar), each bottom corner on some
    /// screen's full frame; closed edges, `edgeTolerance`. A Dock strip, at
    /// the bottom or on a side, is inside the full frame, so a bar parked
    /// partly over it is kept; any screen per corner, so is one parked across
    /// the seam of two side-by-side screens. A bar whose bottom hangs below
    /// every screen is not, however few points of it are left on one.
    private static func isReachable(_ bar: CGRect, on screens: [CaptionScreen]) -> Bool {
        let top = [CGPoint(x: bar.minX, y: bar.maxY), CGPoint(x: bar.maxX, y: bar.maxY)]
        let bottom = [CGPoint(x: bar.minX, y: bar.minY), CGPoint(x: bar.maxX, y: bar.minY)]
        return top.allSatisfy { corner in screens.contains { lies(corner, on: belowMenuBar($0)) } }
            && bottom.allSatisfy { corner in screens.contains { lies(corner, on: $0.frame) } }
    }

    /// The screen's full width, between the visible frame's bottom and top.
    private static func belowMenuBar(_ screen: CaptionScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX, y: screen.visibleFrame.minY,
            width: screen.frame.width, height: screen.visibleFrame.height,
        )
    }

    /// Whether `point` lies on `rect`, edges closed and widened by
    /// `edgeTolerance`.
    private static func lies(_ point: CGPoint, on rect: CGRect) -> Bool {
        point.x >= rect.minX - edgeTolerance && point.x <= rect.maxX + edgeTolerance
            && point.y >= rect.minY - edgeTolerance && point.y <= rect.maxY + edgeTolerance
    }

    /// The screen whose full frame the bar overlaps most. Ties go to the one
    /// holding the bar's centre, then to the leftmost, then to the lowest:
    /// only the primary screen's place in `NSScreen.screens` is documented,
    /// so list order would let the same bar land on different screens.
    private static func screenOwning(_ bar: CGRect, among screens: [CaptionScreen]) -> CaptionScreen? {
        let centre = CGPoint(x: bar.midX, y: bar.midY)
        func key(_ screen: CaptionScreen) -> (CGFloat, Int, CGFloat, CGFloat) {
            let overlap = bar.intersection(screen.frame)
            let holdsCentre = screen.frame.contains(centre) ? 1 : 0
            return (overlap.width * overlap.height, holdsCentre, -screen.frame.minX, -screen.frame.minY)
        }
        return screens.filter { key($0).0 > 0 }.max { key($0) < key($1) }
    }
}
