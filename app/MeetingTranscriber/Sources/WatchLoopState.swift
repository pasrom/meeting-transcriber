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
