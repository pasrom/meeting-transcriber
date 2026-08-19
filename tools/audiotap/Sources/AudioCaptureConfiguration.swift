import Foundation

/// Everything one capture session is configured with, in one value.
///
/// It exists so that the capture options are described in exactly one list.
/// The session used to take them as ten init parameters, and the app carried a
/// parallel struct of its own plus a hand-written mapping onto that init — so a
/// new option had to be added in three places, and an option missing from the
/// middle one fell back to its default for every real recording without
/// anything failing to say so. There is no mapping left to forget.
///
/// The defaults below are a deliberate affordance, not the old hazard: a caller
/// leaving one out is choosing it, where before a caller could lose an option
/// it had already set.
///
/// Deliberately *not* `@available`-gated, unlike `AudioCaptureSession`, which
/// can only exist on macOS 14.2. Nothing in here touches the hardware, and
/// gating it would force every consumer that merely *describes* a capture to
/// carry the version check too.
public struct AudioCaptureConfiguration: Sendable {
    /// PIDs to capture audio from. For Electron/WebView2 apps (Teams 2.x,
    /// Slack, Discord) this should include the root PID plus helper/renderer
    /// children; for native Cocoa apps a single-element array is fine. Ignored
    /// when `appOutputURL` is nil.
    public let pids: [pid_t]

    /// Where to write the app-audio track, or nil to open no process tap at
    /// all. Nil is the microphone-only shape: the session then has exactly one
    /// channel, so a mic failure is terminal rather than the degradation it is
    /// when an app track is also being recorded.
    public let appOutputURL: URL?

    /// Where to write the mic track, or nil not to record the microphone.
    public let micOutputURL: URL?

    /// What the CATap aggregate device is asked for. The device may renegotiate
    /// mid-session; `AppAudioCapture` resamples every buffer to the speech rate
    /// in the IOProc regardless.
    public let sampleRate: Int
    public let channels: Int

    public let micDeviceUID: String?
    public let debugLogging: Bool

    /// Optional real-time buffer callback for the app audio track (CATap
    /// output, interleaved Float32 at the tap's native rate, typically 48 kHz).
    /// Called from the IOProc thread — non-blocking.
    public let appLiveSink: LiveAudioSink?

    /// Optional real-time buffer callback for the mic track (mono Float32 at
    /// file rate, typically 16 kHz post-resample). Called from the AVAudioEngine
    /// tap thread — non-blocking.
    public let micLiveSink: LiveAudioSink?

    /// Set after the configuration is built, never at construction, because it
    /// is not the caller's decision: the e2e build's composition root injects it
    /// into a configuration the recording path assembled, and every shipped
    /// binary leaves it nil. Inert in production; an e2e build uses it to verify
    /// the mic installTap NSException recovery (issue #379).
    ///
    /// The one `var`, and the one field the init does not take. Every other
    /// field is a `let` the init must assign, so the compiler still checks that
    /// a newly added option is carried — which is the guarantee this type
    /// exists for. Add a new option as a `let`; a `var` here would be a silent
    /// nil.
    public var micDebugFault: DebugTapFault?

    /// The tracks and the capture format have no defaults on purpose. "Which
    /// tracks does this record" and "in what format" are the questions a caller
    /// has to answer out loud, and the recording path answers both from its own
    /// named constants — a default here would be a second copy of those numbers
    /// that nothing would notice drifting. What is left describes optional
    /// extras, where leaving one out is a choice.
    public init(
        pids: [pid_t],
        appOutputURL: URL?,
        micOutputURL: URL?,
        sampleRate: Int,
        channels: Int,
        micDeviceUID: String? = nil,
        debugLogging: Bool = false,
        appLiveSink: LiveAudioSink? = nil,
        micLiveSink: LiveAudioSink? = nil,
    ) {
        self.pids = pids
        self.appOutputURL = appOutputURL
        self.micOutputURL = micOutputURL
        self.sampleRate = sampleRate
        self.channels = channels
        self.micDeviceUID = micDeviceUID
        self.debugLogging = debugLogging
        self.appLiveSink = appLiveSink
        self.micLiveSink = micLiveSink
    }
}
