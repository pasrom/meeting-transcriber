import CoreAudio
import Foundation

/// The input device the microphone diagnostics name.
///
/// It exists because the diagnostics answered a different question than the one
/// they were asked. They resolved `kAudioHardwarePropertyDefaultInputDevice`,
/// the system default, while the engine may have been pointed at another
/// device. With a device configured the line then named a microphone that was
/// not recording, so a field report built on it could not be resolved either
/// way (issue #724).
///
/// Both fields are optional separately: CoreAudio can answer one property and
/// decline the other, and a name without a UID is still worth printing.
struct MicInputDevice: Equatable, Sendable {
    let uid: String?
    let name: String?
}

/// The `[debug] Mic input device:` line.
///
/// Composed here rather than interpolated at the logging site so the effect is
/// assertable: a test can prove that the device the session reported is the
/// device the line names, which counting the read alone never showed.
///
/// The shape is what a log reader greps for and what field reports quote, so
/// two things are held fixed: a field CoreAudio would not answer stays `"?"`,
/// and the rate keeps the `%f` rendering os_log gave it (`24000.000000`, not
/// `24000.0`).
func micInputDeviceLogLine(
    device: MicInputDevice?, hardwareRate: Double, hardwareChannels: UInt32,
) -> String {
    let rate = String(format: "%f", hardwareRate)
    return "[debug] Mic input device: name=\(device?.name ?? "?") uid=\(device?.uid ?? "?")"
        + " hwRate=\(rate) hwChannels=\(hardwareChannels)"
}
