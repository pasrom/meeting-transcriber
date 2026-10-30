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
///
/// It also hands out one reading per recording for a track that has been at
/// exact zeros since its first buffer (`silentSinceFirstBuffer`, issue #671).
/// That is not an edge and counts toward nothing the stop summary reports.
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
        /// The track has carried only exact zeros since its first buffer, for
        /// about `silentSinceFirstBufferSeconds` of buffers arriving. Once per
        /// recording, and not an edge (issue #671).
        case silentSinceFirstBuffer
    }

    /// How long buffers must have arrived with no signal ever before the one-off
    /// `silentSinceFirstBuffer` reading.
    static let silentSinceFirstBufferSeconds: TimeInterval = 60
    /// The same threshold in 5 s ticks, which is what the observer counts.
    static let silentSinceFirstBufferTicks =
        Int((silentSinceFirstBufferSeconds / DebugRMSReporter.reportIntervalSeconds).rounded(.up))

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

    /// Ticks seen with buffers arriving and no signal ever.
    private var silentSinceFirstBufferTicksSeen = 0

    mutating func observe(_ ages: ChannelSignalAges) -> Event? {
        // A run already open stays open when buffers stop: the transport dying
        // is not signal returning.
        guard ages.buffersArrive else { return nil }
        guard let energyAge = ages.zeroRunWhileBuffersArrive else {
            // Never a sample of signal. The publisher's energy stamp never
            // resets, so no open run ever lands here; the check keeps a track
            // that carried signal from being misread should that ever change.
            return inZeroRun ? nil : observeSilentSinceFirstBufferTick()
        }

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

    /// A track that never carried a sample of signal opens no zero run (see
    /// `zeroRunWhileBuffersArrive`), so without this nothing would read the
    /// tapped processes between start and stop, and the `start` reading is
    /// taken before a call's audio is up. Mid-call, `outputDevices` against the
    /// device line's `defaultOutput` is what can tell a tap denied by TCC
    /// (issue #524, output still on the default device) from a call that sent
    /// its far end into a voice-processing device from the first second
    /// (issue #671); whether the HAL lists that device there is still to be
    /// seen on a live call. Not an edge: it opens no run, touches no counter
    /// and does not spend the edge cap. The count passes the threshold once,
    /// so the reading is once per recording.
    private mutating func observeSilentSinceFirstBufferTick() -> Event? {
        silentSinceFirstBufferTicksSeen += 1
        guard silentSinceFirstBufferTicksSeen == Self.silentSinceFirstBufferTicks else { return nil }
        return .silentSinceFirstBuffer
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
        guard buffersArrive else { return nil }
        return secondsSinceLastEnergy
    }

    /// Buffers no older than `SilentTrackObserver.maxBufferAge`: the one
    /// definition of "still arriving". With it true, a nil
    /// `zeroRunWhileBuffersArrive` means exactly a track that never carried a
    /// sample, which is how the observer tells the two apart with one branch.
    var buffersArrive: Bool {
        guard let bufferAge = secondsSinceLastBuffer else { return false }
        return bufferAge <= SilentTrackObserver.maxBufferAge
    }
}
