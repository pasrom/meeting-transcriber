// The part of a quit that `WatchLoop` answers for and that does not need its
// private state: what a stop that recorded nothing means while quitting.
// `finishForQuit` stays in `WatchLoop.swift`, next to the watch task it waits
// for; where a stopped recording goes is in `WatchLoop+Enqueue.swift`.
import Foundation

extension WatchLoop {
    /// During a quit, a recording that ended before it captured anything is
    /// nothing recorded, not a failure to report in the middle of quitting.
    func isNothingRecordedAtQuit(_ error: any Error) -> Bool {
        guard finishingForQuit, case .noAudioData? = error as? RecorderError else { return false }
        return true
    }
}
