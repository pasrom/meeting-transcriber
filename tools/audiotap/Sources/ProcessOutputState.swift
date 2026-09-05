import CoreAudio
import Foundation

/// What a tapped process's CoreAudio object says about its output (issue #672).
///
/// Two properties, and it is worth being precise about what each buys, because
/// one of them looks more useful than it is.
///
/// `kAudioProcessPropertyIsRunningOutput` is 1 when the process is running IO
/// with at least one active output stream. It separates a dead tap from a
/// process that rendered nothing at all. It does **not** separate a muted or
/// silent far end from a dead tap, because a stream rendering zeroes still
/// reports true. That limit is why this is instrumentation and not a trigger.
///
/// `kAudioProcessPropertyDevices` on the output scope says where the process's
/// output actually went: straight to the output device, or into some other
/// device such as a voice-processing aggregate the tap does not follow. That is
/// the distinction the field case in issue #671 turns on, and it is the reason
/// this is worth logging at all.
struct ProcessOutputState: Equatable, Sendable {
    /// A value that was read, or the status that says why it was not. Each
    /// property carries its own, because either can fail on its own: a stored
    /// object id whose process has exited fails both, but a property the OS
    /// version does not implement fails one. Collapsing them to a value plus a
    /// nullable status would make "no output devices" and "could not ask"
    /// indistinguishable, and a reader would draw the first conclusion from the
    /// second.
    enum Reading<Value: Equatable & Sendable>: Equatable, Sendable {
        case value(Value)
        case failed(OSStatus)

        /// `String(describing:)` already renders an array of ids as
        /// `[73, 512]` and an empty one as `[]`, which is exactly the
        /// distinction the failure case has to stay apart from.
        var rendered: String {
            switch self {
            case let .value(value): String(describing: value)
            case let .failed(status): "?(\(status))"
            }
        }
    }

    let process: TappedProcess
    let isRunningOutput: Reading<Bool>
    let outputDevices: Reading<[AudioObjectID]>

    var summary: String {
        "pid=\(process.pid) object=\(process.audioObjectID) "
            + "isRunningOutput=\(isRunningOutput.rendered) "
            + "outputDevices=\(outputDevices.rendered)"
    }
}

/// The HAL side of `ProcessOutputState`. Separated so the reads have one home
/// and the value type stays free of CoreAudio calls.
///
/// **Never call this on the write queue.** It is a synchronous HAL round trip
/// through the same coreaudiod that can stop answering, and `AppTapSession`
/// drains the write queue with a `sync`, so a read wedged there would wedge
/// every capture teardown and restart behind it. That is the shape of issue
/// #588. `SilentTrackDiagnostics` owns the queue this belongs on.
enum ProcessOutputProbe {
    static func readAll(_ processes: [TappedProcess]) -> [ProcessOutputState] {
        processes.map(read)
    }

    static func read(_ process: TappedProcess) -> ProcessOutputState {
        ProcessOutputState(
            process: process,
            isRunningOutput: readIsRunningOutput(process.audioObjectID),
            outputDevices: readOutputDevices(process.audioObjectID),
        )
    }

    private static func readIsRunningOutput(
        _ objectID: AudioObjectID,
    ) -> ProcessOutputState.Reading<Bool> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return .failed(status) }
        return .value(value != 0)
    }

    private static func readOutputDevices(
        _ objectID: AudioObjectID,
    ) -> ProcessOutputState.Reading<[AudioObjectID]> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard sizeStatus == noErr else { return .failed(sizeStatus) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return .value([]) }

        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &ids)
        guard status == noErr else { return .failed(status) }
        // The second call updates `size`, and the list can have shrunk between
        // the two. Without the trim the tail would be logged as device 0.
        return .value(Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)))
    }
}
