import Foundation

/// Whether the app picker can start a recording, and if not, why.
///
/// A value rather than two booleans in the view because the two blockers are not
/// interchangeable. A missing selection is visible on screen and needs no words;
/// a recording already running is invisible from the picker and is the reason a
/// press would otherwise appear to do nothing. So the recording case outranks the
/// selection case: picking an app would not help, and saying "pick an app" there
/// would send the user the wrong way.
enum AppPickerStartState: Equatable {
    /// Nothing in the way.
    case ready
    /// No app picked yet.
    case noSelection
    /// A manual recording owns the watch loop, or is on its way to owning it.
    /// Starting a second one used to abandon the first: its audio was never
    /// enqueued while its recorder kept capturing, retained by its own monitor
    /// task (issue #624).
    case manualRecordingActive

    /// - Parameter startWouldBeRefused: `WatchingController.isManualRecording`,
    ///   the *wide* predicate. The picker asks whether a start would be refused,
    ///   and it is refused in both halves: while a manual start is still in
    ///   flight, and once its loop exists. The loop-only predicate is the menu
    ///   bar's different question, "is there a recording I can stop".
    ///
    ///   Both halves are reachable, because the menu gates *opening* this
    ///   window, not its persistence. It closes only on its own Start or Cancel,
    ///   so a picker opened during an in-flight start is still there once the
    ///   loop exists, and re-renders through both states. Getting this wrong in
    ///   either direction is silent: the loop-only predicate leaves a lingering
    ///   picker offering Start during a live recording, where the press is
    ///   refused and the window closes as if it had worked.
    static func resolve(hasSelection: Bool, startWouldBeRefused: Bool) -> Self {
        if startWouldBeRefused { return .manualRecordingActive }
        return hasSelection ? .ready : .noSelection
    }

    var allowsStart: Bool {
        self == .ready
    }

    /// What to tell the user, or nil when the state speaks for itself.
    var explanation: String? {
        switch self {
        case .ready, .noSelection:
            nil

        case .manualRecordingActive:
            "Another recording is already starting or under way. The menu bar shows it once it is running."
        }
    }
}
