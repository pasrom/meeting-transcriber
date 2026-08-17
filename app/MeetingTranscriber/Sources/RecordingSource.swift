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

    var capturedChannels: CapturedChannels {
        switch self {
        case .appAndMic: .micAndApp
        case .appOnly: .appOnly
        case .micOnly: .micOnly
        }
    }

    /// How this source names its target in logs. One wording so `PID 1234`
    /// finds every line about that recording, whichever subsystem wrote it.
    var logDescription: String {
        appPID.map { "PID \($0)" } ?? "microphone only"
    }
}

/// Which capture channels a recording actually opens.
///
/// The health monitors need exactly this and nothing else about the source.
/// They read per-channel levels, and `RecordingProvider` documents `-120` dBFS
/// as "no capture session is active **or** the tap stopped delivering buffers",
/// so a level alone cannot tell a channel that was never opened from one that
/// died. Without this they report the first as the second.
/// The three values mirror `RecordingSource`'s three cases, and the memberwise
/// init stays private so the fourth combination stays unbuildable: a recording
/// with neither channel is the state `RecordingSource` exists to rule out, and
/// a projection of it must not quietly hand that state back.
struct CapturedChannels: Equatable {
    let mic: Bool
    let app: Bool

    private init(mic: Bool, app: Bool) {
        self.mic = mic
        self.app = app
    }

    /// The ordinary dual-source recording, and the default the monitors assume
    /// when nobody says otherwise.
    static let micAndApp = Self(mic: true, app: true)
    /// "No Microphone (app audio only)".
    static let appOnly = Self(mic: false, app: true)
    /// A microphone-only recording (issue #633).
    static let micOnly = Self(mic: true, app: false)
}
