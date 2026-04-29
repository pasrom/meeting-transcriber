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

/// Convert seconds to mach_absolute_time() ticks (inverse of machTicksToSeconds).
func secondsToMachTicks(_ seconds: Double) -> UInt64 {
    let nanos = seconds * 1_000_000_000
    return UInt64(nanos * Double(machTimebaseInfo.denom) / Double(machTimebaseInfo.numer))
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

/// Read a CFString-valued audio property. Returns nil if the property is unavailable.
func readCFStringAudioProperty(
    _ id: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain,
    )
    var s: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &s)
    guard status == noErr, let cf = s?.takeRetainedValue() else { return nil }
    return cf as String
}

/// Bundle ID of a CoreAudio process AudioObject (e.g. "com.microsoft.teams2").
public func getProcessBundleID(_ processObjectID: AudioObjectID) -> String? {
    readCFStringAudioProperty(processObjectID, kAudioProcessPropertyBundleID)
}

/// Human-readable name of the default output device (e.g. "AirPods Pro", "MacBook Pro Speakers").
public func getDefaultOutputDeviceName() -> String? {
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
    return readCFStringAudioProperty(deviceID, kAudioObjectPropertyName)
}

/// Process executable name (e.g. "MSTeams") for a PID. Returns "?" on lookup failure.
public func getExecutableName(pid: pid_t) -> String {
    var name = [CChar](repeating: 0, count: 1024)
    let result = proc_name(pid, &name, UInt32(name.count))
    if result <= 0 { return "?" }
    return String(cString: name)
}

/// Resolve the AudioObjectID of the system default input or output device.
private func resolveDefaultDevice(selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID,
    ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
}

func getDefaultInputDeviceUID() -> String? {
    resolveDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        .flatMap { readCFStringAudioProperty($0, kAudioDevicePropertyDeviceUID) }
}

func getDefaultInputDeviceName() -> String? {
    resolveDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        .flatMap { readCFStringAudioProperty($0, kAudioObjectPropertyName) }
}

/// Transport type of the default output device as a short string
/// (e.g. "Bluetooth", "USB", "Built-In", "AirPlay", "Aggregate").
func getDefaultOutputDeviceTransportType() -> String? {
    guard let deviceID = resolveDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice) else {
        return nil
    }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    var raw: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &raw) == noErr else { return nil }
    return transportTypeNames[raw] ?? "Unknown(\(raw))"
}

private let transportTypeNames: [UInt32: String] = [
    kAudioDeviceTransportTypeBuiltIn: "Built-In",
    kAudioDeviceTransportTypeUSB: "USB",
    kAudioDeviceTransportTypeBluetooth: "Bluetooth",
    kAudioDeviceTransportTypeBluetoothLE: "Bluetooth-LE",
    kAudioDeviceTransportTypeHDMI: "HDMI",
    kAudioDeviceTransportTypeDisplayPort: "DisplayPort",
    kAudioDeviceTransportTypeAirPlay: "AirPlay",
    kAudioDeviceTransportTypeAVB: "AVB",
    kAudioDeviceTransportTypeThunderbolt: "Thunderbolt",
    kAudioDeviceTransportTypeAggregate: "Aggregate",
    kAudioDeviceTransportTypeVirtual: "Virtual",
    kAudioDeviceTransportTypeContinuityCaptureWired: "ContinuityCapture-Wired",
    kAudioDeviceTransportTypeContinuityCaptureWireless: "ContinuityCapture-Wireless",
]

func getDefaultOutputDeviceSampleRate() -> Double? {
    guard let deviceID = resolveDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice) else {
        return nil
    }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr else { return nil }
    return rate
}
