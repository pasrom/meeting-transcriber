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
}

@available(macOS 14.2, *)
extension AudioCaptureSession: AudioCapturing {}

/// Everything `DualSourceRecorder.start()` decides before any hardware is
/// touched: which process tree to tap, where each track is written, which
/// microphone to open.
///
/// Passed to the capture-session factory rather than assembled inside it, so a
/// test can build a session that touches nothing and still see the decisions
/// under test — above all which tracks a `RecordingSource` opens at all, which
/// is the difference between a microphone-only recording and one with a tap.
/// Field order mirrors `AudioCaptureSession.init` so the two lists can be
/// diffed by eye when a capture option is added.
struct CaptureSessionRequest {
    /// The process tree to tap, empty when no tap is opened.
    let pids: [pid_t]
    /// Where the raw app track is written, or nil to open no process tap at
    /// all. Nil is the microphone-only shape, not a tap that captured nothing.
    let appOutputURL: URL?
    let sampleRate: Int
    let channels: Int
    /// Where the mic track is written, or nil when the microphone is not
    /// recorded ("No Microphone").
    let micOutputURL: URL?
    let micDeviceUID: String?
    let debugLogging: Bool
    let appLiveSink: LiveAudioSink?
    let micLiveSink: LiveAudioSink?
}

/// Builds the capture session a recording runs on. Injected into
/// `DualSourceRecorder` so `start()` and `stop()` — which carry the in-progress
/// marker crash recovery keys on — can be driven without audio hardware.
typealias CaptureSessionFactory = @MainActor (CaptureSessionRequest) throws -> any AudioCapturing

/// The production capture session: real taps on real hardware.
enum LiveCaptureSession {
    @MainActor
    static func make(_ request: CaptureSessionRequest) throws -> any AudioCapturing {
        // The one place the 14.2 floor is stated, and the compiler requires it
        // here: `AudioCaptureSession` is gated and this function is not. Every
        // caller reaches a real session through here, so no copy of this check
        // is needed anywhere else — and a copy elsewhere would be unenforced.
        guard #available(macOS 14.2, *) else { throw RecorderError.unsupportedOS }

        // Mic device-change e2e (issue #379): inject a one-shot tap fault so the
        // app self-triggers a mid-recording restart with an invalid format and
        // the lane can verify the installTap NSException recovery. Compiled ONLY
        // in the e2e build (run_app.sh -DE2E_FAULT_INJECTION); the fault is
        // physically absent from every shipped binary.
        #if E2E_FAULT_INJECTION
            let micDebugFault: DebugTapFault? = DebugTapFault(triggerRestartAfter: 2)
        #else
            let micDebugFault: DebugTapFault? = nil
        #endif

        return AudioCaptureSession(
            pids: request.pids,
            appOutputURL: request.appOutputURL,
            sampleRate: request.sampleRate,
            channels: request.channels,
            micOutputURL: request.micOutputURL,
            micDeviceUID: request.micDeviceUID,
            debugLogging: request.debugLogging,
            appLiveSink: request.appLiveSink,
            micLiveSink: request.micLiveSink,
            micDebugFault: micDebugFault,
        )
    }
}
