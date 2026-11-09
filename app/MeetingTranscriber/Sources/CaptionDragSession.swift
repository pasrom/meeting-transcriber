// Which moves of the caption panel are the user's drag and get saved. Pure,
// with the button state passed in, so every case can be pinned without a mouse.
import Foundation

/// Screen-coordinate translation from the mouse and panel origins at drag start.
struct CaptionDragTranslation {
    let startMouseLocation: CGPoint
    let startOrigin: CGPoint
    /// The origin the drag last set: the drop, since the frame at mouse-up
    /// may already be the system's. Nil until the drag has moved the panel,
    /// so an Option-click is no drop.
    var lastOrigin: CGPoint?

    func origin(at mouseLocation: CGPoint) -> CGPoint {
        CGPoint(
            x: startOrigin.x + mouseLocation.x - startMouseLocation.x,
            y: startOrigin.y + mouseLocation.y - startMouseLocation.y,
        )
    }
}

/// Direct dragging has no slide after mouse-up, so later moves must not overwrite the user's position.
struct CaptionDragSession {
    private var buttonDown = false

    mutating func mouseDown() {
        buttonDown = true
    }

    mutating func mouseUp() {
        reset()
    }

    mutating func reset() {
        buttonDown = false
    }

    mutating func shouldSaveMove(buttonPressed: Bool) -> Bool {
        if !buttonPressed { reset() }
        return buttonDown
    }
}
