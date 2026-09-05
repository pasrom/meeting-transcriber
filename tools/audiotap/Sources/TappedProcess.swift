import CoreAudio
import Foundation

/// One process the tap was built from, kept so its state can be read again
/// later. `startCapture` translates PIDs to CoreAudio process objects and used
/// to drop the ids on the floor; a diagnostic that asks "what is the state of
/// the objects this tap is attached to" needs the ids the `CATapDescription` was
/// actually built from, not a fresh translation, which can answer about a
/// different object after a PID is reused.
struct TappedProcess: Equatable, Sendable {
    let pid: pid_t
    let audioObjectID: AudioObjectID
}
