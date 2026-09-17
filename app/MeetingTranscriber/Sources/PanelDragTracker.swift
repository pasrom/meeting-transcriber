import Foundation

/// Moves a window by hand: remembers where inside the frame the mouse went
/// down and keeps that point under the cursor as the mouse moves. Pure value
/// type so the arithmetic is testable without a window.
///
/// Exists because `isMovableByWindowBackground` stopped moving windows whose
/// content view is an `NSHostingView` on macOS 27 (measured: identical panels
/// with a plain `NSView` still move; style mask, level and collection
/// behaviour make no difference). The mouse-down, drag and up events all
/// still reach the window, so the window can do the moving itself.
struct PanelDragTracker: Equatable {
    private var grabOffset: NSPoint?

    /// The mouse went down at `mouse` (screen coordinates) while the frame's
    /// bottom-left corner was at `frameOrigin`.
    mutating func begin(mouse: NSPoint, frameOrigin: NSPoint) {
        grabOffset = NSPoint(x: mouse.x - frameOrigin.x, y: mouse.y - frameOrigin.y)
    }

    mutating func end() {
        grabOffset = nil
    }

    /// Where the frame's origin belongs for the cursor now at `mouse`, or nil
    /// when no drag is in progress.
    func origin(forMouse mouse: NSPoint) -> NSPoint? {
        guard let grabOffset else { return nil }
        return NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
    }
}
