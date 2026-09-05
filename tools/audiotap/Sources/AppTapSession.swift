import CoreAudio
import Foundation

/// The HAL calls a session makes when it gives its objects back, injectable so
/// the release choreography can be asserted without audio hardware. The real
/// implementation is the only one that ships; the seam exists because the
/// ordering below is the part that goes wrong silently.
@available(macOS 14.2, *)
struct AppTapSessionHAL {
    var stopDevice: @Sendable (AudioObjectID, AudioDeviceIOProcID) -> Void
    var destroyIOProc: @Sendable (AudioObjectID, AudioDeviceIOProcID) -> Void
    var destroyAggregate: @Sendable (AudioObjectID) -> Void
    var destroyTap: @Sendable (AudioObjectID) -> Void

    static let real = Self(
        stopDevice: { AudioDeviceStop($0, $1) },
        destroyIOProc: { AudioDeviceDestroyIOProcID($0, $1) },
        destroyAggregate: { AudioHardwareDestroyAggregateDevice($0) },
        destroyTap: { AudioHardwareDestroyProcessTap($0) },
    )
}

/// The HAL objects one capture attempt builds: a process tap, the private
/// aggregate device wrapping it, and the IOProc registration that delivers its
/// buffers.
///
/// They used to live in three fields on `AppAudioCapture`, written as the attempt
/// progressed. That made "who owns these" a question about timing rather than
/// about a reference: an attempt that returned after the session was sealed had
/// to be cleaned up by reaching back into fields a newer attempt might already
/// have overwritten, and every failure path had to remember to blank what it had
/// released. Two defects came out of exactly that shape, both of them silent.
///
/// Here the attempt gets an object instead. Whoever holds it destroys it, once,
/// and a stale attempt destroys its own rather than reaching into shared state.
/// `@unchecked Sendable` because a built session is handed from the queue that
/// built it to the main queue for adoption. Safety comes from ownership, not from
/// locking: exactly one thread holds a session at a time, the handoff goes through
/// a queue hop that establishes happens-before, and the only mutable state is
/// `procID` (attached before the handoff) and `destroyed`. Destroying from a
/// second thread concurrently would be a data race, which is why the rule is
/// ownership rather than a defensive flag.
@available(macOS 14.2, *)
final class AppTapSession: @unchecked Sendable {
    let tapID: AudioObjectID
    /// The processes this tap was built from, kept so a diagnostic can ask them
    /// what their output is doing (issue #672). Stored rather than re-translated
    /// because a fresh translation can answer about a different object after a
    /// PID is reused, and because re-translating is another HAL call. Defaults
    /// to empty so a session built by a test seam is honest about having none.
    let tappedProcesses: [TappedProcess]
    /// Filled in as the attempt gets further. A session that never got past the
    /// tap still cleans up correctly, which is the point: every failure path
    /// hands back one object instead of remembering which of three ids it owns.
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    /// The rate this attempt resolved before starting its device. The
    /// measured-rate correction from the first callback deliberately does NOT
    /// live here: that value is read on the write queue for every buffer and
    /// again after the session is gone, so it stays a published copy on the
    /// capture object.
    private(set) var resolvedSampleRate = 0
    private(set) var procID: AudioDeviceIOProcID?

    private let hal: AppTapSessionHAL
    private let drain: () -> Void
    private var destroyed = false

    init(
        tapID: AudioObjectID,
        tappedProcesses: [TappedProcess] = [],
        hal: AppTapSessionHAL = .real,
        drain: @escaping () -> Void,
    ) {
        self.tapID = tapID
        self.tappedProcesses = tappedProcesses
        self.hal = hal
        self.drain = drain
    }

    /// The aggregate wraps the tap, so it can only exist once the tap does. The
    /// resolved rate arrives with it because resolving reads both ids.
    func attach(aggregateID: AudioObjectID, resolvedSampleRate: Int) {
        self.aggregateID = aggregateID
        self.resolvedSampleRate = resolvedSampleRate
    }

    /// The registration is attached after the fact because creating it needs the
    /// aggregate this session already owns, and the block it installs has to be
    /// able to reach the session it belongs to.
    func attach(procID: AudioDeviceIOProcID?) {
        self.procID = procID
    }

    /// Give everything back, in the order the HAL requires, at most once.
    ///
    /// The drain sits between destroying the registration and destroying the
    /// device on purpose: `AudioDeviceStop` does not synchronise against blocks
    /// already dispatched onto the write queue, so without the barrier a late
    /// buffer writes into a file descriptor the caller is about to close.
    ///
    /// Single-shot because the alternative is a caller tracking whether someone
    /// else got there first, which is the bookkeeping this type exists to remove.
    ///
    /// Ids that were never created are skipped rather than handed to the HAL: an
    /// attempt that threw while building owns only part of the set, and asking
    /// CoreAudio to destroy `kAudioObjectUnknown` is not something this code
    /// should rely on being harmless.
    ///
    /// Must not be called ON the write queue: the drain is a `sync` onto it and
    /// would deadlock. Every caller today is either the main queue or the restart
    /// queue, and the injected-drain tests cannot catch a violation.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true

        if let procID {
            hal.stopDevice(aggregateID, procID)
            hal.destroyIOProc(aggregateID, procID)
            self.procID = nil
        }
        drain()
        if aggregateID != kAudioObjectUnknown {
            hal.destroyAggregate(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            hal.destroyTap(tapID)
        }
    }
}
