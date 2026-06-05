import CoreAudio
import Foundation

/// Tap-creation error mapping for `AppAudioCapture`. Extracted to a sibling file
/// so `AppAudioCapture.swift` stays under the 600-line lint cap — same pattern
/// as `AppAudioCapture+LiveSink.swift`.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Translates an `AudioHardwareCreateProcessTap` OSStatus to a human hint.
    /// Exposed `internal` for unit tests.
    static func describeTapError(_ status: OSStatus) -> String {
        switch status {
        case -12988:
            "OSStatus -12988: likely missing permission. " +
                "Check System Settings → Privacy & Security → Screen Recording " +
                "and enable Meeting Transcriber."

        case -10851:
            "OSStatus -10851 (kAudioUnitErr_InvalidProperty): " +
                "the tap target may have exited before the tap was created."

        case -50:
            "OSStatus -50 (paramErr): invalid CATapDescription parameter " +
                "(target process may not be capturable)."

        default:
            "OSStatus \(status): unrecognised — see CoreAudio headers."
        }
    }
}
