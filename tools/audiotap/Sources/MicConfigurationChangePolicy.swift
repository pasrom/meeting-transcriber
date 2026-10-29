import CoreAudio
import Foundation

/// What a microphone engine's input unit is bound to and delivers: the device
/// and the hardware-side format the tap was installed for.
struct MicEngineConfiguration: Equatable, Sendable {
    var deviceID: AudioDeviceID
    var sampleRate: Double
    var channelCount: UInt32
    var formatID: AudioFormatID = kAudioFormatLinearPCM
    var formatFlags: AudioFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved
    var bitsPerChannel: UInt32 = 32
}

/// What a configuration change finds on a pinned engine.
struct MicConfigurationChangeReading: Equatable, Sendable {
    /// Right after the configured device was pinned and the unit confirmed it.
    var atStart: MicEngineConfiguration
    var now: MicEngineConfiguration
    var isRunning: Bool
    /// The configured UID still resolves to the device pinned at start. The
    /// unit can keep reporting a device that was just unplugged.
    var pinnedDevicePresent = true
}

enum MicConfigurationChangeAction: Equatable, Sendable {
    case restart
    case ignore
}

/// Whether an `AVAudioEngineConfigurationChange` on the microphone engine has
/// to restart it (issues #706, #724).
///
/// Pinning a configured device on a fresh `AVAudioEngine` moves its input unit
/// off the private default-device aggregate the engine binds it to, and the
/// engine reports that move as a configuration change about 100 ms after it
/// started. Measured on macOS 26 with the built-in microphone, configured
/// while also being the system default: one change per engine, after which the
/// unit is still on the pinned device, in the same format, running and
/// delivering. Restarting on that change built a new engine that pinned again
/// and was told again, about five times a second with no buffer in between,
/// for the whole call. Which device is configured does not matter, only that
/// one is; with nothing pinned no such change was raised.
///
/// Only a pinned engine is judged here: an unpinned unit sits on the
/// aggregate, whose ID stays put when the default input changes beneath it,
/// so an unchanged reading would prove nothing. No reading (nil) restarts.
/// The progress watchdog is the net for a change ignored wrongly, but only for
/// an engine that stops delivering buffers: it is rebuilt at its next
/// deadline. One that keeps delivering after a change this cannot see is not.
enum MicConfigurationChangePolicy {
    static func decide(_ reading: MicConfigurationChangeReading?) -> MicConfigurationChangeAction {
        guard let reading, reading.isRunning, reading.pinnedDevicePresent,
              reading.now == reading.atStart else { return .restart }
        return .ignore
    }
}
