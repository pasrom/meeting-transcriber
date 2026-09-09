import CoreAudio
import Foundation

/// What the aggregate device says about itself, and which output device it was
/// bound to (issue #693).
///
/// `AudioDeviceStart` returning `noErr` says the object exists, not that IO is
/// running, and only `kAudioDevicePropertyDeviceIsRunning` tells the two apart.
/// A field report of "the tap created fine and no buffer ever arrived" is
/// undecidable without it, because every other line in the log reads the same
/// in both cases.
///
/// The default output device rides along because the aggregate binds its only
/// sub-device by UID at creation, and the UID alone cannot say whether the
/// object behind it is still the one the system renders to. Its nominal rate is
/// here for the reason `ProcessOutputState` carries the device list: a
/// Bluetooth headset changes rate under the aggregate without changing the
/// default output device, so nothing else notices it moved.
///
/// Reuses `ProcessOutputState.Reading` rather than declaring its own, so "could
/// not ask" renders the same way in both diagnostics and a reader does not have
/// to learn two spellings of the same idea.
struct AggregateRunState: Equatable, Sendable {
    let aggregateID: AudioObjectID
    let isRunning: ProcessOutputState.Reading<Bool>
    let defaultOutputDeviceID: ProcessOutputState.Reading<AudioObjectID>
    let defaultOutputRate: ProcessOutputState.Reading<Int>

    var summary: String {
        "aggregate=\(aggregateID) running=\(isRunning.rendered) "
            + "defaultOutput=\(defaultOutputDeviceID.rendered) "
            + "defaultOutputRate=\(defaultOutputRate.rendered)"
    }
}

/// The HAL side of `AggregateRunState`, kept beside it for the same reason
/// `ProcessOutputProbe` sits beside `ProcessOutputState`: the reads have one
/// home and the value type stays free of CoreAudio calls.
///
/// **Never call this on the write queue or the main queue**, for the reason
/// spelled out on `SilentTrackDiagnostics`: these are synchronous HAL round
/// trips through the same coreaudiod that can stop answering, and that object
/// owns the queue they belong on.
enum AggregateRunProbe {
    static func read(aggregateID: AudioObjectID) -> AggregateRunState {
        // One read of the default output device, not one per field. The id and
        // the rate have to describe the same device or the line says the
        // opposite of what it exists to say, and two reads even microseconds
        // apart can straddle exactly the profile switch this is meant to catch.
        let device = defaultOutputDeviceReading()
        let rate: ProcessOutputState.Reading<Int> = switch device {
        case let .value(deviceID): nominalSampleRateReading(deviceID: deviceID)
        case let .failed(status): .failed(status)
        }
        return AggregateRunState(
            aggregateID: aggregateID,
            isRunning: isRunningReading(aggregateID),
            defaultOutputDeviceID: device,
            defaultOutputRate: rate,
        )
    }

    private static func isRunningReading(
        _ deviceID: AudioObjectID,
    ) -> ProcessOutputState.Reading<Bool> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return .failed(status) }
        return .value(value != 0)
    }
}
