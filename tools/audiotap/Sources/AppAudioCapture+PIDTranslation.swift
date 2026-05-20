import CoreAudio
import Foundation

/// Translates PIDs to CoreAudio process `AudioObjectID`s for `CATapDescription`.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Translate every stored PID. PIDs that fail translation (helper has
    /// no audio-object entry, process exited between enumeration and tap
    /// creation) are dropped — that's expected for Electron helper trees
    /// where only the audio-emitting renderer owns an audio object.
    /// Throws when no PID at all could be translated, since the resulting
    /// tap would have nothing to listen to.
    func translatePIDs() throws -> [AudioObjectID] {
        let translated = pids.compactMap { Self.translatePID($0) }
        guard !translated.isEmpty else {
            throw NSError(
                domain: "audiotap", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to translate any of \(pids.count) PIDs to audio objects",
                ],
            )
        }
        return translated
    }

    static func translatePID(_ pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePid = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &mutablePid, &size, &objectID,
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }
}
