import Foundation

/// Value-type snapshot of `WatchLoop`'s five observable fields. The class
/// keeps the fields as `@Observable` stored properties (so SwiftUI bindings
/// continue working); `WatchLoopState` is the form tests and other readers
/// (e.g. the RPC state snapshot) use for equality checks against a single
/// value rather than five field-wise comparisons.
struct WatchLoopState: Equatable {
    var phase: WatchLoop.State
    var currentMeeting: DetectedMeeting?
    var lastError: String?
    var detail: String
    var manualRecordingInfo: ManualRecordingInfo?

    /// Initial state at `WatchLoop` construction. Matches the field
    /// defaults declared on the class — see `WatchLoop.init`.
    static let initial = Self(
        phase: .idle,
        currentMeeting: nil,
        lastError: nil,
        detail: "",
        manualRecordingInfo: nil,
    )
}

/// The read-only views of the loop's own state. They touch nothing private, so
/// they live next to the value type they produce rather than in `WatchLoop.swift`.
extension WatchLoop {
    var isActive: Bool {
        state != .idle
    }

    /// What the live recording captures, or nil when nothing is recording.
    /// The channel-health monitors need it: they see only per-channel levels,
    /// and -120 dBFS means both "never opened" and "stopped delivering".
    ///
    /// The source the recorder was started with, not one rebuilt from the
    /// settings: "No Microphone" is read live (issue #706), so rebuilding would
    /// follow a toggle made mid-recording and describe channels that were
    /// never opened.
    ///
    /// Both start paths assign `recordingSource` before the `.recording`
    /// transition. `apply` commits every field before it calls
    /// `onStateChange`, and the channel-health wiring reads this from inside
    /// that callback, so a path that assigned it later would read nil there and
    /// silently disable the indicator for that whole path, which is not a
    /// failure any of the flags downstream can distinguish from a quiet
    /// recording.
    var activeRecordingSource: RecordingSource? {
        state == .recording ? recordingSource : nil
    }

    /// Value-type view of the five observable fields. Useful for tests,
    /// `AppState+RPC` snapshots, and as the input/output shape for the
    /// upcoming pure-function reducer slice.
    var snapshot: WatchLoopState {
        WatchLoopState(
            phase: state,
            currentMeeting: currentMeeting,
            lastError: lastError,
            detail: detail,
            manualRecordingInfo: manualRecordingInfo,
        )
    }
}
