import Foundation

/// Common surface for the system/app-audio capture backends consumed by
/// `AudioCaptureSession`. Two implementations exist:
///
/// - `SCKAudioCapture` — ScreenCaptureKit system-audio capture. This is the
///   default. It captures the audio of every app you can hear, *including*
///   conferencing apps (Microsoft Teams, Zoom) that render their call audio
///   through WebRTC / Voice-Processing pipelines a CoreAudio process tap
///   cannot see.
/// - `AppAudioCapture` — CoreAudio process tap (`CATapDescription`). Lighter
///   weight and lower latency, but Teams/Zoom call audio arrives zero-filled
///   (silent) because their downlink bypasses the process-tap mixdown. Kept as
///   an opt-in fallback via `MEETINGTRANSCRIBER_AUDIO_BACKEND=catap`.
///
/// Both deliver interleaved float32 PCM to the same file descriptor, so the
/// downstream mix/resample pipeline is backend-agnostic.
@available(macOS 14.2, *)
protocol AppAudioCapturing: AnyObject {
    /// Begin capturing. Throws if the backend cannot start (missing permission,
    /// no display, tap creation failure).
    func start() throws

    /// Stop capturing and drain any pending writes before the caller closes the
    /// output file descriptor.
    func stop()

    /// Instantaneous capture level in dBFS, decayed to -120 when no buffer has
    /// arrived in the last 0.5 s. Drives the menu-bar silence indicator.
    var currentLevelDBFS: Double { get }

    /// `mach_absolute_time()` of the first delivered audio buffer (0 before any).
    /// Used to align the app track against the mic track.
    var appFirstFrameTime: UInt64 { get }

    /// Actual sample rate observed from the delivered buffers.
    var actualSampleRate: Int { get }

    /// Actual channel count observed from the delivered buffers.
    var actualChannels: Int { get }
}

@available(macOS 14.2, *)
extension AppAudioCapture: AppAudioCapturing {}
