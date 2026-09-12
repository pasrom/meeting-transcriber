import CoreAudio
import Foundation
import os

/// Owns the three things the silent-track instrumentation needs that a value
/// type cannot hold: a queue the HAL reads may safely block on, a guard so a
/// read that never returns costs one parked thread instead of a growing pile,
/// and the observer's state, which the write queue updates and the main queue
/// reads at stop (issue #672).
///
/// One object rather than four stored properties on `AppAudioCapture`, which is
/// close enough to the 600-line lint cap that four would not fit.
///
/// **Why a dedicated queue.** The reads cannot go on `writeQueue`: that is the
/// IOProc's delivery queue, and `AppTapSession.destroy()` drains it with a
/// `sync`, so a HAL call wedged there would wedge every capture teardown and
/// restart behind it, which is the shape of issue #588. They cannot go on the
/// main queue for the same reason one step worse. And they must not go on
/// `restartQueue`, which is bounded by `RestartArbiter` for work that owns HAL
/// resources; a diagnostic sharing it could delay a restart that matters.
final class SilentTrackDiagnostics: @unchecked Sendable {
    /// One probe's worth of readings. Grouped rather than returned separately
    /// so both travel the same queue, the same in-flight guard and the same
    /// reason: the device state is only ever interesting next to the process
    /// state, and a second mechanism for it would have to re-earn the wedge
    /// protection this one already has (issue #693).
    struct ProbeSnapshot: Sendable, Equatable {
        let processes: [ProcessOutputState]
        /// Nil when there is no aggregate to ask about, which is every probe
        /// taken while no tap is installed.
        let device: AggregateRunState?
    }

    typealias Probe = @Sendable ([TappedProcess], AudioObjectID) -> ProbeSnapshot

    /// The reading that ships. Both halves are synchronous HAL round trips, so
    /// this must only ever be called on the queue below.
    static let readAll: Probe = { processes, aggregateID in
        ProbeSnapshot(
            processes: ProcessOutputProbe.readAll(processes),
            device: aggregateID == kAudioObjectUnknown
                ? nil : AggregateRunProbe.read(aggregateID: aggregateID),
        )
    }

    /// What a probe request came to. `skipped` is reported rather than swallowed
    /// because the reason it happens is a read still inside coreaudiod, which is
    /// the failure class this whole object is shaped around: without a line, a
    /// wedged first probe would silence every later one for the whole recording
    /// and the log would simply be missing, with nothing saying why.
    enum Outcome: Equatable {
        case read(ProbeSnapshot)
        case skipped
    }

    /// Called on the diagnostics queue with the reason the probe was taken and
    /// what came of it, except for `skipped`, which is reported inline on the
    /// caller's thread because no work was queued. Injected rather than logging
    /// here so the wording and the privacy annotations stay next to the other
    /// capture logging, and so a test can assert without reading the system log.
    typealias Sink = @Sendable (String, Outcome) -> Void

    private let queue = DispatchQueue(
        label: "com.meetingtranscriber.audiotap.diagnostics", qos: .utility,
    )
    private let probe: Probe
    private let sink: Sink

    /// The observer and the in-flight flag, behind one lock. Scoped access
    /// rather than a queue hop because `observe` is called from the IOProc's
    /// write queue and must not hop anywhere, and `withLock` rather than a bare
    /// lock because it makes an unbalanced early return structurally impossible.
    /// Same primitive its neighbours use for a state machine behind a lock.
    private struct State {
        var observer = SilentTrackObserver()
        var probeInFlight = false
        /// The processes of the most recently installed tap. The stop summary
        /// cannot read them off the session: `.stopAndRetry` clears it before
        /// any restart attempt launches, and only adoption puts one back, so on
        /// every give-up and mid-restart stop the session is nil. That is
        /// exactly the recording whose process state is worth having.
        var lastInstalledProcesses: [TappedProcess] = []
        /// The aggregate of the most recently installed tap, for the same
        /// reason as the processes above: at stop the session is often gone.
        var lastInstalledAggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The deadlines armed for the capture attempt currently installed, held so
    /// the first buffer and teardown can disarm them. Kept out of `State` and
    /// behind its own lock because `DispatchWorkItem` is not `Sendable` and
    /// `State` has to stay so; this class is already `@unchecked Sendable`, and
    /// cancelling a work item is documented as safe from any thread.
    private let armedLock = NSLock()
    private var armedNoBufferProbes: [DispatchWorkItem] = []

    /// How a deadline is armed. Nil means the diagnostics queue's own
    /// `asyncAfter`, which is what production uses; a test injects one so it
    /// decides when each deadline is reached. Proving a probe did *not* fire by
    /// sleeping past a real five-second deadline is a coin toss on a loaded
    /// machine, not an assertion.
    typealias DelayedWork = @Sendable (TimeInterval, DispatchWorkItem) -> Void

    private let delayedWork: DelayedWork?

    init(
        probe: @escaping Probe = SilentTrackDiagnostics.readAll,
        sink: @escaping Sink,
        delayedWork: DelayedWork? = nil,
    ) {
        self.probe = probe
        self.sink = sink
        self.delayedWork = delayedWork
    }

    /// Arm one probe per offset, replacing anything a previous attempt armed.
    ///
    /// Called from `startCapture()`, so a device-change restart re-arms rather
    /// than stacking: without the replacement the old attempt's deadlines would
    /// keep firing against an aggregate that no longer exists, and every rebuild
    /// would add another set.
    ///
    /// The processes and the aggregate are captured by value for the same
    /// reason the IOProc block captures its session: a deadline that outlives
    /// its own attempt must report the aggregate it was armed for, not whatever
    /// the newest attempt installed.
    func scheduleNoBufferProbes(
        _ processes: [TappedProcess],
        aggregateID: AudioObjectID,
        schedule: NoFirstBufferProbeSchedule = .production,
    ) {
        cancelNoBufferProbes()
        let items = schedule.offsets.map { offset in
            let reason = schedule.reason(after: offset)
            return (offset, DispatchWorkItem { [weak self] in
                _ = self?.probeAsync(processes, aggregateID: aggregateID, reason: reason)
            })
        }
        armedLock.lock()
        armedNoBufferProbes = items.map(\.1)
        armedLock.unlock()
        for (offset, item) in items {
            if let delayedWork {
                delayedWork(offset, item)
            } else {
                queue.asyncAfter(deadline: .now() + offset, execute: item)
            }
        }
    }

    /// Disarm every pending probe. Called when the first buffer arrives, which
    /// is why a healthy recording emits none of these lines, and again on
    /// teardown so a destroyed aggregate is never read.
    func cancelNoBufferProbes() {
        armedLock.lock()
        let pending = armedNoBufferProbes
        armedNoBufferProbes = []
        armedLock.unlock()
        for item in pending {
            item.cancel()
        }
    }

    /// Feed one tick's signal ages and hand back the edge, if this tick is one.
    /// Called on the write queue.
    func observe(_ ages: ChannelSignalAges) -> SilentTrackObserver.Event? {
        state.withLock { $0.observer.observe(ages) }
    }

    /// What the stop summary reports. Safe from any thread.
    var counters: (zeroRuns: Int, longestZeroRun: TimeInterval) {
        state.withLock { ($0.observer.zeroRuns, $0.observer.longestZeroRun) }
    }

    /// The processes of the most recently installed tap, which is what the stop
    /// summary asks about. See `State.lastInstalledProcesses`.
    var lastInstalledProcesses: [TappedProcess] {
        state.withLock { $0.lastInstalledProcesses }
    }

    /// The aggregate of the most recently installed tap. See
    /// `State.lastInstalledAggregateID`.
    var lastInstalledAggregateID: AudioObjectID {
        state.withLock { $0.lastInstalledAggregateID }
    }

    /// Called from the tap adoption, on the main queue.
    func remember(_ processes: [TappedProcess], aggregateID: AudioObjectID) {
        state.withLock { state in
            state.lastInstalledProcesses = processes
            state.lastInstalledAggregateID = aggregateID
        }
    }

    /// Take a process-state reading off every hot queue, unless one is already
    /// running. Returns whether this call started one, which is what makes the
    /// guard assertable.
    @discardableResult
    func probeAsync(
        _ processes: [TappedProcess], aggregateID: AudioObjectID, reason: String,
    ) -> Bool {
        let started = state.withLock { state -> Bool in
            guard !state.probeInFlight else { return false }
            state.probeInFlight = true
            return true
        }
        guard started else {
            sink(reason, .skipped)
            return false
        }

        // Strongly, deliberately. The stop probe is requested from
        // `AppAudioCapture.stop()`, and `AudioCaptureSession.stop()` releases the
        // capture object a few statements later, before this queue gets to run
        // the block: with a weak reference the stop reading was lost almost every
        // time. Holding self here costs a queue, two closures and a lock until
        // the read returns, which is the same lifetime a wedged read already has.
        queue.async {
            let snapshot = self.probe(processes, aggregateID)
            // Cleared as soon as the read is back, before the sink hears of it,
            // so the guard means exactly what `Outcome.skipped` says: a read
            // still inside coreaudiod, never a line still being written. A
            // caller the sink wakes can therefore start the next probe straight
            // away. Reads still never overlap, since the queue is serial; the
            // flag only ever bounds how many blocks a wedged read can collect
            // behind it, and a clear the read must return to reach keeps that.
            self.state.withLock { $0.probeInFlight = false }
            self.sink(reason, .read(snapshot))
        }
        return true
    }
}
