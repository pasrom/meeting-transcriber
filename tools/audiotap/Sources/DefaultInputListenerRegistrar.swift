import CoreAudio
import Foundation

/// Registers and removes the microphone handler's listener for the system's
/// default-input-device changes. A seam so a test can watch the handler add
/// and remove its listener without registering one on the host, where a real
/// device change would reach it and restart the capture under the test's feet.
struct DefaultInputListenerRegistrar: Sendable {
    /// Registers the listener, delivered on the main queue; returns its status.
    let add: @Sendable (@escaping AudioObjectPropertyListenerBlock) -> OSStatus
    /// Removes a listener `add` registered.
    let remove: @Sendable (@escaping AudioObjectPropertyListenerBlock) -> Void

    /// The real CoreAudio registration on the system object.
    static let system = Self(
        add: { listener in
            var address = defaultInputAddress
            return AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener,
            )
        },
        remove: { listener in
            var address = defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener,
            )
        },
    )

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
}
