import AudioTapLib
import Foundation

/// The part of `AudioCaptureSession` one recording drives.
///
/// Lives here rather than in AudioTapLib because it is the *consumer's* view of
/// that class, not part of what the capture library offers: the library's own
/// tests drive `AppAudioCapture` and `MicCaptureHandler` directly and need no
/// seam over the session.
///
/// Separately, it is deliberately *not* `@available`-gated even though its only
/// production conformer is. The OS floor belongs to the hardware, so it is
/// stated once, in `LiveCaptureSession.make`, where the compiler enforces it.
/// Gating the role instead would put an `@available` type back into
/// `DualSourceRecorder`'s stored properties — exactly what the type-erased
/// `AnyObject` storage there used to be working around — and would also let a
/// caller on 14.0 declare an `any AudioCapturing` it could never obtain.
protocol AudioCapturing: AnyObject {
    func start() throws
    func stop() -> AudioCaptureResult
    var appLevelDBFS: Double { get }
    var micLevelDBFS: Double { get }
    var appCaptureGaveUp: Bool { get }
    var micCaptureGaveUp: Bool { get }

    /// How long each channel has gone without a buffer, and without one
    /// carrying signal. See `ChannelSignalAges` for why the levels above
    /// cannot answer that.
    /// Required rather than defaulted: the sibling `RecordingProvider` defaults
    /// the same property to a healthy channel, and two defaults pointing
    /// opposite ways would hand a double "dead" or "delivering" purely by which
    /// protocol it sits behind.
    var appSignalAges: ChannelSignalAges { get }
    var micSignalAges: ChannelSignalAges { get }
}

@available(macOS 14.2, *)
extension AudioCaptureSession: AudioCapturing {}

/// Builds the capture session a recording runs on. Injected into
/// `DualSourceRecorder` so `start()` and `stop()` — which carry the in-progress
/// marker crash recovery keys on — can be driven without audio hardware.
///
/// The configuration is assembled by the recording path and passed *in* rather
/// than built inside the factory, which is what lets a test see the decisions a
/// start made — above all which tracks a `RecordingSource` opens at all, the
/// difference between a microphone-only recording and one with a tap. It is the
/// capture library's own type rather than a struct of this module's; that type
/// documents why.
typealias CaptureSessionFactory = @MainActor (AudioCaptureConfiguration) throws -> any AudioCapturing

/// The production capture session: real taps on real hardware.
enum LiveCaptureSession {
    /// The configuration this build is allowed to open a session with.
    ///
    /// Mic device-change e2e (issue #379): the fault makes the app self-trigger
    /// a mid-recording restart with an invalid format so the lane can verify
    /// the installTap NSException recovery. It is compiled ONLY into the e2e
    /// build (run_app.sh -DE2E_FAULT_INJECTION).
    ///
    /// The `#else` is what keeps the fault physically absent from every shipped
    /// binary, and it is not redundant: the field is a `var` on a struct that
    /// ships, so whatever a caller set would otherwise travel straight through
    /// to a `MicCaptureHandler` whose fault machinery is always compiled.
    /// Overwriting here means no shipped build can reach the session with a
    /// fault set, whoever built the configuration.
    ///
    /// Separate from `make` only so that guarantee can be asserted: `make`
    /// returns a session that keeps its configuration to itself, so a test can
    /// see what was decided here and nothing else can.
    static func configurationForThisBuild(
        _ configuration: AudioCaptureConfiguration,
    ) -> AudioCaptureConfiguration {
        var configuration = configuration
        #if E2E_FAULT_INJECTION
            configuration.micDebugFault = DebugTapFault(triggerRestartAfter: 2)
        #else
            configuration.micDebugFault = nil
        #endif
        return configuration
    }

    @MainActor
    static func make(_ configuration: AudioCaptureConfiguration) throws -> any AudioCapturing {
        // The one place the 14.2 floor is stated, and the compiler requires it
        // here: `AudioCaptureSession` is gated and this function is not. Every
        // caller reaches a real session through here, so no copy of this check
        // is needed anywhere else — and a copy elsewhere would be unenforced.
        guard #available(macOS 14.2, *) else { throw RecorderError.unsupportedOS }
        return AudioCaptureSession(configurationForThisBuild(configuration))
    }
}
