import CoreAudio
import Foundation

/// The ordered list of devices the process tap's private aggregate may be
/// anchored to, best guess first.
///
/// The aggregate needs one real sub-device to clock against, and the tap
/// carries what the tapped process renders *to that device*. Pick the wrong
/// one and the tap delivers well-formed buffers of exact digital zeros,
/// indefinitely, with no error anywhere.
///
/// **Transport does not predict whether audio flows, and an earlier version of
/// this type was built on the assumption that it does.** That version refused
/// to anchor to a `Virtual`-transport default and redirected to physical
/// hardware at capture start. It was wrong, and it broke recordings that had
/// been working: with Rogue Amoeba Loopback's "Studio Display Surround" as the
/// system default — transport `Virtual` — three meetings recorded 29.4, 3.6 and
/// 1.7 minutes at -25.3, -20.9 and -27.7 dBFS, with 98.7%, 92.8% and 85.8% of
/// samples nonzero. The meeting app followed the system default and rendered
/// straight into that virtual device, so anchoring there was not merely
/// acceptable, it was the only correct answer.
///
/// The genuinely broken case looks identical from the outside. During a
/// 68.7-minute meeting, Teams' ModuleHost pointed
/// `kAudioHardwarePropertyDefaultOutputDevice` at Teams' own loopback driver
/// (`MSLoopbackDriverDevice_UID`, also transport `Virtual`) four times, while
/// the unified log shows the same process still rendering the call to the real
/// hardware throughout at -19.7 dBFS. The app track holds not one nonzero
/// sample across the 45.5 minutes that driver held the default.
///
/// So: two virtual defaults, one live and one dead, told apart by no property
/// of the device. The real question was never "is this device virtual" but "is
/// the tap receiving audio at this anchor", and that can only be answered by
/// trying.
///
/// Hence a list rather than a rule. **Position 0 is always the current system
/// default**, whatever its transport, which makes the cases that already worked
/// byte-identical to the behavior that produced them. The rest of the list is
/// what `SilentTapWatchdog` walks, one step per trip, and only once it has
/// *proven* the current anchor delivers nothing. Empirical, and self-correcting
/// in a way a deterministic rule cannot be — a rule re-derives its own wrong
/// answer on every retry, so the retries converge on the failure instead of
/// away from it.
///
/// **Not a process-selection bug.** ModuleHost was in the tap's PID list the
/// whole time and was correctly resolved. The tapped processes were right and
/// the anchor device was wrong — worth stating plainly, because the symptom (an
/// app track with no meeting audio in it) is exactly what a missed helper PID
/// looks like, and `ProcessTreeEnumerator` / `ProcessResponsibility` are the
/// first places anyone would go looking.
///
/// Pure decision logic, no CoreAudio calls — `OutputDeviceEnumeration` does the
/// querying and hands the result here, which is what makes the ordering
/// testable on a machine with no audio hardware at all.
enum OutputDeviceAnchorPolicy {
    /// The subset of a CoreAudio output device this decision needs.
    struct Device: Equatable {
        let uid: String
        let name: String
        /// Raw `kAudioDevicePropertyTransportType` value.
        let transportType: UInt32
        /// Whether any process currently has IO running on this device
        /// (`kAudioDevicePropertyDeviceIsRunningSomewhere`).
        ///
        /// Defaulted so the many call sites that only care about ordering by
        /// transport do not have to state it.
        let isRunningIO: Bool

        init(uid: String, name: String, transportType: UInt32, isRunningIO: Bool = false) {
            self.uid = uid
            self.name = name
            self.transportType = transportType
            self.isRunningIO = isRunningIO
        }
    }

    /// Why a candidate is in the list at the position it holds. Logged on every
    /// attempt so a diagnostics log makes the search legible afterwards.
    enum Reason: Equatable {
        /// The current system default output. Always position 0: the meeting
        /// app most often follows it, and when it does this is the only anchor
        /// that carries anything at all.
        case systemDefault
        /// The most recent anchor at which the tap actually delivered nonzero
        /// samples. Deliberately not "the last physical device" — what earns a
        /// device this position is demonstrated delivery, not its transport.
        case lastKnownGood
        /// Built-in output, preferred over other hardware because it is the one
        /// device that is always present and cannot vanish mid-recording.
        case builtInFallback
        /// Any remaining physical output, in HAL enumeration order.
        case physicalFallback
    }

    struct Candidate: Equatable {
        let uid: String
        let reason: Reason
    }

    /// Transports that mean another program is standing between the app and the
    /// speakers.
    ///
    /// **No longer decides anything at capture start** — see the type comment
    /// for why that was wrong. It survives because it still orders the
    /// *fallbacks*: once the default has been proven dead, a physical device is
    /// the better next guess, since a second interposed driver is an unlikely
    /// place for the audio to have gone. It is also worth logging.
    ///
    /// `Aggregate` is excluded for the reason that kept it excluded before: a
    /// multi-output device is a render target the user configured and
    /// applications really do render into it, so treating it as suspect would
    /// demote a perfectly good fallback.
    static func isInterposed(transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeVirtual
    }

    /// Build the ordered candidate list.
    ///
    /// - Parameters:
    ///   - defaultDevice: the current system default output. Always first.
    ///   - outputDevices: every device on the system with output streams, in
    ///     CoreAudio enumeration order.
    ///   - lastKnownGoodUID: the most recent anchor that demonstrably delivered
    ///     audio. Ignored when that device is no longer present — CoreAudio
    ///     would reject the aggregate rather than fall back for us.
    static func candidates(
        defaultDevice: Device,
        outputDevices: [Device],
        lastKnownGoodUID: String?,
    ) -> [Candidate] {
        var fallbacks: [Candidate] = []
        var seen: Set<String> = [defaultDevice.uid]

        func append(_ uid: String, _ reason: Reason) {
            guard seen.insert(uid).inserted else { return }
            fallbacks.append(Candidate(uid: uid, reason: reason))
        }

        if let lastKnownGoodUID, outputDevices.contains(where: { $0.uid == lastKnownGoodUID }) {
            append(lastKnownGoodUID, .lastKnownGood)
        }

        let physical = outputDevices.filter { !isInterposed(transportType: $0.transportType) }
        if let builtIn = physical.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }) {
            append(builtIn.uid, .builtInFallback)
        }
        for device in physical {
            append(device.uid, .physicalFallback)
        }

        return [Candidate(uid: defaultDevice.uid, reason: .systemDefault)]
            + prioritizingRunningIO(fallbacks, among: outputDevices)
    }

    /// Move devices that currently have IO running to the front of the
    /// fallbacks, preserving the existing order within each group.
    ///
    /// This is the signal that was missing when two recordings were lost to a
    /// fallback that guessed wrong: the meeting app had stopped playing to the
    /// system default and started playing to the headphones, and the watchdog
    /// then advanced to built-in speakers, where nothing was playing either.
    /// Running IO points straight at where the audio went.
    ///
    /// **Deliberately does not touch position 0.** The system default leads
    /// whatever its running state, which is what makes a default the app *is*
    /// rendering into behave exactly as it did before any of this existed. The
    /// signal is also not clean enough to lead with: on one measured incident
    /// the meeting app's loopback device and the headphones were running IO
    /// simultaneously, so "running" alone cannot name the winner. Ordering the
    /// fallbacks costs nothing if it is wrong — the search simply moves on —
    /// while promoting above the default could lose a working recording.
    private static func prioritizingRunningIO(
        _ candidates: [Candidate], among devices: [Device],
    ) -> [Candidate] {
        let running = Set(devices.filter(\.isRunningIO).map(\.uid))
        guard !running.isEmpty else { return candidates }
        // A stable partition, not a sort: within each group the reason ordering
        // above still decides, so a known-good device stays ahead of untried
        // hardware that happens to share its running state.
        return candidates.filter { running.contains($0.uid) }
            + candidates.filter { !running.contains($0.uid) }
    }
}
