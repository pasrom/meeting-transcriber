import Foundation

/// Notices when the app track enters and leaves a run of exact zeros while
/// buffers keep arriving, so the transition is in the log rather than only the
/// end state (issue #672).
///
/// Nothing in the capture path acted on the samples it recorded. The app layer
/// eventually notices (`ChannelFaultMonitor` reports `digitalSilence` after a
/// debounce) but the library, which is where a rebuild would have to happen and
/// where the tap's own state can be read, saw nothing. A field case ran 1193 of
/// 1194 seconds at exact zeros with buffers delivered throughout, and the only
/// evidence anyone had afterwards was the finished file.
///
/// This is the sensor, not the actuator. It says when a run began and how long
/// it lasted, which is what the log needs to tell a dying tap apart from a
/// meeting app that moved its output somewhere the tap does not follow. Whether
/// a run should trigger a tap rebuild is a separate question, and it is
/// deliberately not answered here: two of the three live readings of the field
/// case mean a rebuild changes nothing, and each rebuild is an exposure to the
/// wedge class of issue #588, which is terminal for the channel.
///
/// Driven from the existing 5 s tick with `ChannelSignalAges`, so it needs no
/// clock of its own and no timer. That does mean it cannot see a tap whose
/// IOProc stopped, since the tick is IOProc-driven; that failure is `noBuffers`
/// and the app layer already reports it.
struct SilentTrackObserver: Equatable {
    /// How long the track must have been at exact zeros before the run is worth
    /// a log line. Not a rebuild threshold: this only writes to the log, so it
    /// can afford to be shorter than anything that would act.
    static let zeroRunThreshold: TimeInterval = 10
    /// Buffers must still be arriving for a zero run to mean anything. Beyond
    /// this the fault is the transport, not the content.
    static let maxBufferAge: TimeInterval = 2
    /// A pathological toggle must not flood the log. The counters keep going
    /// past this, so the stop summary stays honest.
    static let maxEdgesPerRecording = 20

    enum Event: Equatable {
        /// The track carried signal and has now been at exact zeros for
        /// `afterSignalSeconds`.
        case enteredZeroRun(afterSignalSeconds: TimeInterval)
        /// Signal came back after `durationSeconds` of zeros.
        case exitedZeroRun(durationSeconds: TimeInterval)
    }

    private(set) var edges = 0
    private(set) var zeroRuns = 0
    private(set) var longestZeroRun: TimeInterval = 0
    /// The longest energy age seen inside the run currently open, and zero when
    /// none is. At the moment signal returns the age has already reset, so the
    /// run's length has to have been remembered while it was still running, and
    /// a run only ever opens above the threshold, so this doubles as the flag.
    private var currentRunPeak: TimeInterval = 0

    var inZeroRun: Bool {
        currentRunPeak > 0
    }

    mutating func observe(_ ages: ChannelSignalAges) -> Event? {
        // A run already open stays open when this is nil: the transport dying
        // is not signal returning.
        guard let energyAge = ages.zeroRunWhileBuffersArrive else { return nil }

        guard inZeroRun else {
            guard energyAge >= Self.zeroRunThreshold else { return nil }
            zeroRuns += 1
            currentRunPeak = energyAge
            longestZeroRun = max(longestZeroRun, currentRunPeak)
            return emit(.enteredZeroRun(afterSignalSeconds: energyAge))
        }
        currentRunPeak = max(currentRunPeak, energyAge)
        longestZeroRun = max(longestZeroRun, currentRunPeak)
        guard energyAge < Self.zeroRunThreshold else { return nil }
        let duration = currentRunPeak
        currentRunPeak = 0
        return emit(.exitedZeroRun(durationSeconds: duration))
    }

    /// Counts the edge and hands it back, or swallows it once the cap is
    /// reached. The state above is updated either way.
    private mutating func emit(_ event: Event) -> Event? {
        guard edges < Self.maxEdgesPerRecording else { return nil }
        edges += 1
        return event
    }
}

extension ChannelSignalAges {
    /// How long the track has carried only exact zeros, counted only while
    /// buffers keep arriving; nil when it cannot be a zero run at all. The one
    /// definition the observer and the watchdog share.
    ///
    /// Nil for a channel that never carried a single non-zero sample: that is
    /// the signature of a tap that was never allowed to hear the app (issue
    /// #524), a different failure with a different fix. Nil too once buffers
    /// are older than `SilentTrackObserver.maxBufferAge`: buffers stopping is
    /// `noBuffers`, which the app layer reports, and the content of a
    /// transport that stopped says nothing.
    var zeroRunWhileBuffersArrive: TimeInterval? {
        guard let energyAge = secondsSinceLastEnergy,
              let bufferAge = secondsSinceLastBuffer,
              bufferAge <= SilentTrackObserver.maxBufferAge
        else { return nil }
        return energyAge
    }
}
