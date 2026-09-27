// Which moves of the caption panel are the user's drag and get saved. Pure,
// with times passed in, so every case can be pinned without a mouse.
import Foundation

/// A user's drag of the caption bar, as seen from the panel's move
/// notifications.
///
/// Measured with a panel set up like the caption panel, on real drags: the
/// panel reports moves continuously while it is dragged (about every
/// 100 ms), keeps following the mouse after Option is released as long as
/// the button stays down (one drag ran on some 600 pt), and after mouse-up
/// keeps sliding for 200 to 400 ms, often to a screen edge, so where it
/// comes to rest can be hundreds of points from the mouse-up point. Option
/// therefore says nothing about whether a move is the user's; the mouse
/// button and the slide after it do.
///
/// A session starts on a mouse-down on the panel. Every move while the
/// button is down is saved. After mouse-up a move within `settleWindow` of
/// the mouse-up, or of the previous saved move, is still saved and extends
/// the window; once the window passes without a move the session is over.
///
/// Each move is checked against the physical button. Found up while the
/// session still thinks it down (a mouse-up that went elsewhere, or one not
/// yet handled after a stall of the main thread), the move is taken as the
/// mouse-up: it is saved and the settle window starts from it, so a stall
/// never costs the end of a drag. The controller also resets the session
/// whenever it shows or hides the panel.
///
/// Accepted limits: a move by anything else (the system relocating the
/// panel) inside the settle window right after a drag is saved as well;
/// after a missed mouse-up, never seen in the measurement, the next move is
/// saved once before the session closes, however late it comes; and the
/// event routing of a real drag (the down reaching the panel, the up being
/// delivered) rests on the measurement above, not on tests, which inject
/// the events with `sendEvent`.
struct CaptionDragSession {
    /// How long after mouse-up, or after the last move of the slide, a move
    /// still counts as the drag's.
    static let settleWindow: TimeInterval = 0.5

    private var buttonDown = false
    private var settleDeadline: TimeInterval?

    mutating func mouseDown() {
        buttonDown = true
        settleDeadline = nil
    }

    /// Starts the settle phase; ignored without a mouse-down on the panel.
    mutating func mouseUp(at time: TimeInterval) {
        guard buttonDown else { return }
        buttonDown = false
        settleDeadline = time + Self.settleWindow
    }

    /// Ends any drag at once.
    mutating func reset() {
        buttonDown = false
        settleDeadline = nil
    }

    /// Whether a move reported at `time` is the drag's and is saved.
    /// `buttonPressed` is the physical state of the left button then.
    mutating func shouldSaveMove(at time: TimeInterval, buttonPressed: Bool) -> Bool {
        if buttonDown {
            if buttonPressed { return true }
            mouseUp(at: time)
        }
        guard let deadline = settleDeadline, time <= deadline else {
            settleDeadline = nil
            return false
        }
        settleDeadline = time + Self.settleWindow
        return true
    }
}
