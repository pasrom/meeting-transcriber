import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "OutputDeviceEnumeration")

/// CoreAudio queries backing `OutputDeviceAnchorPolicy`. Split from the policy
/// so the rules stay testable without hardware: everything here talks to the
/// HAL and returns plain values, everything there is a pure function of those
/// values.
enum OutputDeviceEnumeration {
    /// Every device on the system that can play audio, in HAL enumeration
    /// order. Input-only devices are excluded — an aggregate anchored to one
    /// has no output clock to follow.
    static func outputDevices() -> [OutputDeviceAnchorPolicy.Device] {
        deviceIDs().compactMap(describeOutputDevice)
    }

    /// The system default output as the policy wants it. `nil` when the HAL
    /// cannot answer, which is the same condition `getDefaultOutputDeviceUID`
    /// already treats as fatal for a capture attempt.
    static func defaultOutputDevice() -> OutputDeviceAnchorPolicy.Device? {
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
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.error("Cannot resolve the default output device (status: \(status, privacy: .public))")
            return nil
        }
        // Deliberately not `describeOutputDevice`: the default output is by
        // definition an output, and a driver that answers the stream-config
        // query oddly should not make the whole capture attempt fail.
        guard let uid = readCFStringAudioProperty(deviceID, kAudioDevicePropertyDeviceUID) else {
            logger.error("Cannot read the default output device UID")
            return nil
        }
        return OutputDeviceAnchorPolicy.Device(
            uid: uid,
            name: readCFStringAudioProperty(deviceID, kAudioObjectPropertyName) ?? "?",
            transportType: transportType(deviceID) ?? 0,
            isRunningIO: isRunningSomewhere(deviceID),
        )
    }

    /// Short transport label for logs, e.g. "Virtual" or "Built-In".
    static func transportLabel(_ raw: UInt32) -> String {
        transportTypeNames[raw] ?? "Unknown(\(raw))"
    }

    // MARK: - Internals

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
        )
        guard sizeStatus == noErr else {
            logger.warning("Cannot enumerate fallback devices (status: \(sizeStatus, privacy: .public))")
            return []
        }
        guard size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids,
        )
        guard status == noErr else {
            logger.warning("Cannot read fallback devices (status: \(status, privacy: .public))")
            return []
        }
        return ids
    }

    private static func describeOutputDevice(_ deviceID: AudioObjectID) -> OutputDeviceAnchorPolicy.Device? {
        guard hasOutputStreams(deviceID) else { return nil }
        guard let uid = readCFStringAudioProperty(deviceID, kAudioDevicePropertyDeviceUID) else {
            logger.warning("Skipping output device \(deviceID, privacy: .public): UID is unavailable")
            return nil
        }
        return OutputDeviceAnchorPolicy.Device(
            uid: uid,
            name: readCFStringAudioProperty(deviceID, kAudioObjectPropertyName) ?? "?",
            transportType: transportType(deviceID) ?? 0,
            isRunningIO: isRunningSomewhere(deviceID),
        )
    }

    /// True when the device exposes at least one output channel. The stream
    /// configuration is a variable-length `AudioBufferList`, so it has to be
    /// read into a sized allocation rather than a fixed struct.
    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            logger.warning("Cannot read output streams for \(deviceID, privacy: .public) (status: \(sizeStatus, privacy: .public))")
            return false
        }
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment,
        )
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
        guard status == noErr else {
            logger.warning("Cannot read output configuration for \(deviceID, privacy: .public) (status: \(status, privacy: .public))")
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self),
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Whether any process on the system currently has IO running on this
    /// device.
    ///
    /// Reported per device rather than per process — it says *someone* is
    /// running IO, not who — which is why it orders fallbacks instead of
    /// choosing the anchor outright. On one measured incident the meeting app's
    /// loopback device and the headphones were both running IO at once.
    ///
    /// A failed query is logged and leaves the device unpromoted.
    private static func isRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running)
        guard status == noErr else {
            logger.warning("Cannot read running I/O for \(deviceID, privacy: .public) (status: \(status, privacy: .public)); leaving it unpromoted")
            return false
        }
        return running != 0
    }

    private static func transportType(_ deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &raw)
        guard status == noErr else {
            logger.warning("Cannot read transport for \(deviceID, privacy: .public) (status: \(status, privacy: .public))")
            return nil
        }
        return raw
    }
}
