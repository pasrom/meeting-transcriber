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
    /// Derived from the fields the `.recording` transition publishes, not
    /// mirrored in a stored property. `apply` commits every field before it
    /// calls `onStateChange`, and the channel-health wiring reads this from
    /// inside that callback, so a stored mirror would have to be assigned
    /// before the phase in every start path. Missing that in one of them reads
    /// as nil and silently disables the indicator for that whole path, which is
    /// not a failure any of the flags downstream can distinguish from a quiet
    /// recording.
    var activeRecordingSource: RecordingSource? {
        guard state == .recording else { return nil }
        if let info = manualRecordingInfo {
            return info.pid.map { .forApp(pid: $0, noMic: noMic) } ?? .micOnly
        }
        return currentMeeting.map { .forApp(pid: $0.windowPID, noMic: noMic) }
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
