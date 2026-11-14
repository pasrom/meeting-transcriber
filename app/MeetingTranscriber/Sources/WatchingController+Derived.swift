import Foundation

extension WatchingController {
    var isWatching: Bool {
        watchLoop?.isActive == true && watchLoop?.isManualRecording == false
    }

    /// Whether a recording is currently in progress (the watch loop is in its
    /// `.recording` state).
    var isRecording: Bool {
        watchLoop?.state == .recording
    }

    /// Whether a manual (app-picker) recording owns the loop, or is on its way
    /// to owning it. Exposed because `toggleWatching` silently refuses in that
    /// state, and a silent refusal is invisible to a remote caller — the
    /// automation API turns this into a 409.
    ///
    /// The in-flight half matters: `startManualRecording` assigns `watchLoop`
    /// only after awaiting the mic gate, so reading the loop alone reports
    /// "no manual recording" for the whole of that window, and a remote start
    /// landing in it would build an auto loop that the manual task then
    /// overwrites without stopping.
    var isManualRecording: Bool {
        manualStartTask != nil || watchLoop?.isManualRecording == true
    }
}
