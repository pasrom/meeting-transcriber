import CoreAudio
import Foundation
import os.log

/// What came of pointing a mic engine's input unit at the configured device.
///
/// One type rather than a raw `OSStatus` at the call site, because the status
/// used to be discarded and the success line logged either way: a rejected pin
/// and an accepted one produced byte-identical output while the recording ran
/// on a microphone the user had not chosen. The cases are also the only ones
/// the bring-up can produce, so the combinations that cannot occur cannot be
/// written down.
///
/// Not `ProcessOutputState.Reading`, which this package already uses to carry
/// an `OSStatus` alongside a value: that one models a *read*, where success
/// hands back something that was not known before. This is a *write*, whose
/// success carries nothing new (the device id was resolved before the call),
/// and it needs a third state for a device that was never configured.
enum MicDevicePinOutcome: Equatable, Sendable {
    /// No device configured. The unit keeps whatever the system hands it, and
    /// there is nothing to report.
    case notRequested
    /// The configured UID translates to no live device, so nothing was
    /// attempted. Common and benign on its own: it is what a headset that is
    /// switched off or out of range looks like.
    case unresolvedUID(String)
    /// `AudioUnitSetProperty` was called and answered, and the unit was then
    /// asked which device it is on. `actual` is that answer, and nil there
    /// means the question could not be put, which is **not** the same as an
    /// answer naming another device. Keeping those apart is the whole reason
    /// `actual` is optional rather than defaulted: `noErr` says the call was
    /// accepted, not that the unit moved, and a failed read says nothing at all.
    case set(uid: String, requested: AudioDeviceID, status: OSStatus, actual: AudioDeviceID?)

    /// How loudly to say it.
    ///
    /// Three levels rather than a bool, because there are three situations and
    /// collapsing any two of them misreports one. A configured device that is
    /// simply absent, and one whose adoption could not be confirmed, are both
    /// ordinary: at error level a sleeping headset would log an error on every
    /// recording and bury the two cases that are not ordinary, a device that
    /// was refused and one that was accepted and then not adopted.
    var level: OSLogType {
        switch self {
        case .notRequested:
            .info

        case .unresolvedUID:
            // os_log has no "warning"; `.default` is the level Console shows as
            // one, and is what the unresolved case used before this type.
            .default

        case let .set(_, requested, status, actual):
            if status != noErr {
                .error // refused outright
            } else if actual == requested {
                .info // accepted and confirmed
            } else if actual == nil {
                .default // accepted, confirmation unavailable
            } else {
                .error // accepted, and the unit is on something else
            }
        }
    }

    /// Which device the diagnostics name.
    ///
    /// The rule lives here, apart from the CoreAudio lookups that feed it, so
    /// it can be tested on a host with no microphone, which is every CI runner
    /// this package builds on. It is the load-bearing sentence of the whole
    /// fix, and it is not "whatever device the unit reports": with nothing
    /// pinned, `AVAudioEngine` binds the input unit to a private aggregate of
    /// its own that merely follows the system default, and naming that answers
    /// nothing.
    ///
    /// The four arms are each a different piece of evidence, and the third is
    /// the one worth reading twice. A set that was accepted and could not be
    /// read back still names the configured device, because the acceptance is
    /// the only evidence there is and it points that way. Falling back to the
    /// system default there would state as fact the opposite of what was
    /// measured, which is the exact failure this type exists to end.
    func deviceToReport(systemDefault: AudioDeviceID?) -> AudioDeviceID? {
        switch self {
        case .notRequested, .unresolvedUID:
            // Nothing was pointed anywhere, so the unit is on the aggregate
            // that follows the default.
            systemDefault

        case let .set(_, requested, status, actual):
            if status != noErr {
                systemDefault // refused: the unit never moved
            } else if actual == nil || actual == requested {
                requested // adopted, or accepted and unconfirmed
            } else {
                systemDefault // accepted, and the unit is somewhere else
            }
        }
    }

    /// What the capture log prints, nil when there is nothing to say. Spelled
    /// out here rather than at the logging site so the wording is under test;
    /// the caller decides only the level.
    ///
    /// **No device UID in here, deliberately.** This line is unconditional, not
    /// behind the verbose-diagnostics toggle, and `PersistentDiagnosticLog`
    /// streams every line at info and above into a file that Settings offers to
    /// export as "a redacted log file". That promise *is* os_log's own
    /// redaction, so a UID marked public here would falsify it: an audio device
    /// UID is stable across boots and a USB one carries the serial or location
    /// id. The device is named in the `[debug] Mic input device:` line instead,
    /// which only exists once the user has turned verbose diagnostics on.
    var logLine: String? {
        switch self {
        case .notRequested:
            nil

        case .unresolvedUID:
            "Mic device not set: the configured microphone is not a live device, recording on the system default input"

        case let .set(_, requested, status, _) where status != noErr:
            "Mic device not set: the configured microphone (ID \(requested)) was refused with OSStatus \(status), recording on the system default input"

        case let .set(_, requested, _, actual) where actual == nil:
            "Mic device set: the configured microphone (ID \(requested)), but the input unit could not be asked to confirm it"

        case let .set(_, requested, _, actual) where actual != requested:
            "Mic device not adopted: the configured microphone (ID \(requested)) was accepted but the input unit reports ID \(actual.map(String.init) ?? "?"), so the recording is not on the configured microphone"

        case let .set(_, requested, _, _):
            "Mic device set: the configured microphone (ID \(requested))"
        }
    }
}
