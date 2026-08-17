import Foundation

/// Whether the menu bar's "Record Microphone" item can start a recording, and
/// if not, why.
///
/// Mirrors `AppPickerStartState`: the menu asks one value what to render rather
/// than assembling the answer from two flags inline, so the reason a disabled
/// item is disabled is decided in one testable place and shown to the user
/// instead of leaving a dead control.
enum MicrophoneRecordingAvailability: Equatable {
    /// Nothing in the way.
    case ready

    /// Something is already recording, so a second start would clobber it
    /// (issue #624). The menu shows Stop Recording in this state anyway; this
    /// case exists so "already recording" is never silently read as ready.
    case recordingActive

    /// The user set "No Microphone (app audio only)".
    ///
    /// Honouring that by starting anyway would record nothing, and overriding it
    /// silently would put on tape the one thing the setting says to keep off it.
    /// So the item stays visible and disabled, with the reason attached: someone
    /// who set this months ago should not be left guessing why the entry does
    /// nothing.
    case blockedByNoMicSetting

    var allowsStart: Bool {
        self == .ready
    }

    /// Why the item is disabled, or nil when it is not. User-facing.
    var disabledReason: String? {
        switch self {
        case .ready: nil
        case .recordingActive: "A recording is already running"
        case .blockedByNoMicSetting: "Turn off \"No Microphone\" in Settings to record the microphone"
        }
    }

    static func resolve(isRecording: Bool, noMic: Bool) -> Self {
        if isRecording { return .recordingActive }
        if noMic { return .blockedByNoMicSetting }
        return .ready
    }
}
