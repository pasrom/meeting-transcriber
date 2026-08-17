import Foundation

/// What a single recording captures.
///
/// Replaces the `(appPID: pid_t, noMic: Bool)` pair the recording path used to
/// pass around. That pair had no way to express "microphone, no app tap"
/// (issue #633) without also being able to express "no app tap and no
/// microphone", which is a recording of nothing. Folding both questions into
/// one value makes that state unrepresentable.
///
/// It also gives the consumers downstream a single thing to switch on. The
/// permission gate needs to know whether a process tap is opened, not which
/// PID it targets, and the channel-health monitors need to know which channels
/// exist at all — a level of `-120` cannot tell a deliberately absent channel
/// from a dead one.
enum RecordingSource: Equatable {
    /// Tap the target process and record the microphone alongside it. The
    /// ordinary meeting and "Record App..." shape.
    case appAndMic(pid: pid_t)

    /// Tap the target process only, because the user set "No Microphone".
    case appOnly(pid: pid_t)

    /// Record the microphone with no process tap at all, for a meeting that
    /// happens in the room rather than in an app.
    case micOnly
}

extension RecordingSource {
    /// The process to tap, or nil when this source opens no tap. Also the
    /// process whose exit ends the recording — a microphone-only session has
    /// none, so only its duration cap applies.
    var appPID: pid_t? {
        switch self {
        case let .appAndMic(pid), let .appOnly(pid): pid
        case .micOnly: nil
        }
    }

    /// Whether a CATap process tap is opened. This is what the Screen Recording
    /// arm of the permission gate is really asking about: that grant is only a
    /// preflightable proxy for the tap, so it has no bearing on a session that
    /// opens none.
    var capturesAppAudio: Bool {
        appPID != nil
    }

    /// Whether the microphone is recorded.
    var capturesMicrophone: Bool {
        switch self {
        case .appAndMic, .micOnly: true
        case .appOnly: false
        }
    }

    /// The source for a recording aimed at a running app, honouring the user's
    /// "No Microphone (app audio only)" setting.
    static func forApp(pid: pid_t, noMic: Bool) -> Self {
        noMic ? .appOnly(pid: pid) : .appAndMic(pid: pid)
    }
}
