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
    typealias Probe = @Sendable ([TappedProcess]) -> [ProcessOutputState]

    /// What a probe request came to. `skipped` is reported rather than swallowed
    /// because the reason it happens is a read still inside coreaudiod, which is
    /// the failure class this whole object is shaped around: without a line, a
    /// wedged first probe would silence every later one for the whole recording
    /// and the log would simply be missing, with nothing saying why.
    enum Outcome: Equatable {
        case read([ProcessOutputState])
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
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(probe: @escaping Probe = ProcessOutputProbe.readAll, sink: @escaping Sink) {
        self.probe = probe
        self.sink = sink
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

    /// Called from the tap adoption, on the main queue.
    func remember(_ processes: [TappedProcess]) {
        state.withLock { $0.lastInstalledProcesses = processes }
    }

    /// Take a process-state reading off every hot queue, unless one is already
    /// running. Returns whether this call started one, which is what makes the
    /// guard assertable.
    @discardableResult
    func probeAsync(_ processes: [TappedProcess], reason: String) -> Bool {
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
            self.sink(reason, .read(self.probe(processes)))
            // After the sink, so a caller waiting for the flag to clear cannot
            // observe it clear before the result was reported.
            self.state.withLock { $0.probeInFlight = false }
        }
        return true
    }
}
