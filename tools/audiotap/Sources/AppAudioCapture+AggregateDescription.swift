import CoreAudio
import Foundation

/// The CFDictionary that describes the private aggregate device wrapping a
/// process tap.
///
/// Pure configuration data: it reads nothing off the instance and owns nothing,
/// which is why it lives here rather than inline in `startCapture`. That
/// function holds the object lifecycle (create, adopt, release, forget), and
/// keeping a twenty-line literal in the middle of it buried the ordering that
/// actually matters.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// - Parameters:
    ///   - nameTag: root PID, embedded in the device name. Purely cosmetic, it
    ///     is what makes an orphaned aggregate identifiable in
    ///     `system_profiler SPAudioDataType`.
    ///   - outputUID: the device the tap follows, used as main sub-device.
    ///   - tapUUID: the process tap to attach.
    static func aggregateDescription(
        nameTag: String,
        outputUID: String,
        tapUUID: String,
    ) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey as String: "audiotap-\(nameTag)",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ],
            ],
        ]
    }
}
