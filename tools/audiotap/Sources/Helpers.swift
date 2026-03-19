import CoreAudio
import Foundation

/// Target sample rate for speech recognition (WhisperKit).
/// Must match `AudioConstants.targetSampleRate` in the app target.
public let speechSampleRate: Double = 16000

/// Cached mach timebase info (constant per boot session).
private let machTimebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

/// Convert mach_absolute_time() ticks to seconds.
func machTicksToSeconds(_ ticks: UInt64) -> Double {
    let nanos = Double(ticks) * Double(machTimebaseInfo.numer) / Double(machTimebaseInfo.denom)
    return nanos / 1_000_000_000.0
}

/// Write all bytes to a file descriptor using POSIX write() — no Data copy, no Foundation overhead.
func writeAllToFileHandle(_ fd: Int32, _ ptr: UnsafeRawPointer, count: Int) {
    var remaining = count
    var offset = 0
    while remaining > 0 {
        let written = write(fd, ptr + offset, remaining)
        if written < 0 {
            if errno == EINTR { continue }
            break
        }
        if written == 0 { break }
        remaining -= written
        offset += written
    }
}

/// Get the UID of the current default output device.
func getDefaultOutputDeviceUID() -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID,
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

    var uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    var uid: Unmanaged<CFString>?
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let uidStatus = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
    guard uidStatus == noErr, let cfUID = uid?.takeRetainedValue() else { return nil }
    return cfUID as String
}
