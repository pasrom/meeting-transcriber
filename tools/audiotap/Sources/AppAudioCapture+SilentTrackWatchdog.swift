import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

/// The opt-in silent-track watchdog (issue #672, part 2): when the app track
/// has sat at exact zeros for `SilentTrackWatchdogPolicy.triggerZeroRunSeconds`
/// while buffers keep arriving and a tapped process still reports output,
/// rebuild the tap and aggregate through the restart path a device change
/// uses. The judgement lives in `SilentTrackWatchdogPolicy`; this file is the
/// wiring and the log lines.
///
/// **A second trigger, the tap that never delivered (issue #693).** An
/// aggregate created and started against a Bluetooth headset mid profile
/// switch can stay dormant for the whole recording: `AudioDeviceStart` returns
/// `noErr`, no IOProc call ever comes, and nothing ticks. The no-first-buffer
/// probes (`NoFirstBufferProbeSchedule`) already read the tapped processes at
/// fixed offsets; with the watchdog on, a reading that shows a process
/// rendering while nothing has arrived opens the same check a zero run would,
/// and the rebuild takes the same path with the same budgets. A fresh
/// aggregate built once the headset has settled starts at once, which is what
/// every measured recovery of this fault was. The rebuilt tap is judged by a
/// tick if it delivers and by its deadline (`noteTapInstalledForWatchdog`)
/// if it does not.
///
/// **Same anchor, same path.** The rebuild goes through
/// `OutputDeviceChangeCoordinator` and `applyAction`, so it gets a fresh
/// `AppTapSession` built by `startCapture()` on the current default output
/// device, a generation-tagged attempt bounded by `RestartArbiter`'s deadline,
/// the shared `CaptureRestartRetryPolicy` budget, and `TimelineAnchor` turning
/// the gap into silence. Nothing here picks a different device.
///
/// **What the arbiter does not bound.** The teardown half of a rebuild,
/// `stopCapture()` and with it `AppTapSession.destroy()`, runs inline on the
/// main queue, unbounded, as it does for every device-change restart; only
/// the attempt that builds the next tap runs under `RestartArbiter`'s
/// deadline. A block inside coreaudiod there is an app freeze, not a lost
/// channel. The no-first-buffer trigger tears down an aggregate that is known
/// not to be cycling, and whether that is more likely to block than tearing
/// down a working one is not measured; it is one more reason this stays
/// opt-in.
///
/// **Three queues.** The tick arrives on the write queue, the process-state
/// read and the decision run on the diagnostics queue, and the rebuild runs on
/// the main queue, where every other restart is driven. The decision is
/// re-checked there against the live ages and the installed tap before
/// anything happens, because by then either can have moved on.
///
/// **The log is the point.** Whether a rebuild restores a dying tap is
/// unmeasured, and these lines are how one recording measures it. They are
/// unconditional, like the observer's, and bounded: rebuild lines by
/// `SilentTrackWatchdogPolicy.maxRebuildsPerRecording`, everything else by
/// `maxLoggedSkips`, the give-up and the cap by happening once. They carry
/// durations, counts, booleans, pids and CoreAudio object ids, never a device
/// name or UID.
@available(macOS 14.2, *)
extension AppAudioCapture {
    /// One line at capture setup, so a log says the watchdog was on without
    /// anyone having to remember the setting. Nothing is logged when it is
    /// off, which keeps "off" identical to a build without it.
    func logSilentTrackWatchdogArmed() {
        guard silentTrackWatchdog else { return }
        typealias Policy = SilentTrackWatchdogPolicy
        logger.info(
            "App audio watchdog: on (check after \(Self.seconds(Policy.triggerZeroRunSeconds), privacy: .public) s of exact zeros, at most one rebuild per \(Self.seconds(Policy.minSecondsBetweenChecks), privacy: .public) s, give up after \(Policy.maxUnrecoveredRebuilds, privacy: .public) rebuilds without signal, at most \(Policy.maxRebuildsPerRecording, privacy: .public) rebuilds per recording)",
        )
    }

    /// Called from the 5 s tick on the write queue with the ages the tick
    /// already read. The stored flag is checked first, so with the watchdog
    /// off the tick takes no further lock and reads no clock.
    func tickSilentTrackWatchdog(ages: ChannelSignalAges, processes: [TappedProcess]) {
        guard silentTrackWatchdog else { return }
        evaluateSilentTrackWatchdog(
            ages: ages,
            now: watchdogNow,
            processes: processes,
        )
    }

    /// The tick's body with its inputs passed in, which is the seam the
    /// restart-path test drives: the ages and the clock come from the level
    /// publisher and the mach clock in production, and neither can be made to
    /// read a minute of zeros in a unit test.
    func evaluateSilentTrackWatchdog(
        ages: ChannelSignalAges, now: TimeInterval, processes: [TappedProcess],
    ) {
        guard let (event, generation) = silentTrackDiagnostics.watchdogTick(ages, now: now) else { return }
        switch event {
        case let .recovered(rebuild, withinSeconds):
            Self.logRecovered(rebuild, withinSeconds: withinSeconds)

        case let .superseded(rebuild):
            Self.logSuperseded(rebuild)

        case let .unrecovered(rebuild, afterSeconds):
            logger.info(
                "App audio watchdog: rebuild \(rebuild, privacy: .public) did not restore signal within \(Self.seconds(afterSeconds), privacy: .public) s",
            )

        case .check:
            // Kept out of the sink: a declined check would otherwise write a
            // line per process every minute. The rebuild line below carries
            // the per-process state of the checks that act. No aggregate: the
            // decision reads only the processes, and every HAL read skipped is
            // one less that can wedge (issue #588).
            let started = silentTrackDiagnostics.probeAsync(
                processes,
                aggregateID: AudioObjectID(kAudioObjectUnknown),
                reason: "watchdog check",
                reportToSink: false,
            ) { [weak self] snapshot in
                self?.concludeSilentTrackCheck(snapshot, generation: generation)
            }
            // Another probe's read is still outstanding. The policy waits out
            // the interval before asking again, and the line is budgeted: a
            // wedged read skips every check for as long as the run lasts.
            if !started {
                silentTrackDiagnostics.watchdogAbandonCheck()
                if silentTrackDiagnostics.watchdogClaimSkipLine() {
                    logger.info("App audio watchdog: check skipped, a process-state read is still outstanding")
                }
            }
        }
    }

    /// Arm the no-first-buffer probes for a tap that was just started, with
    /// the watchdog hearing each reading when it is on and nothing hearing
    /// them when it is off, so that off means what it meant before this
    /// trigger existed: the probes log, and nothing acts. Called by
    /// `startCapture()`; the wiring tests call it by hand, since their
    /// attempt seam replaces that.
    func armNoBufferProbes(
        _ processes: [TappedProcess], aggregateID: AudioObjectID, schedule: NoFirstBufferProbeSchedule = .production,
    ) {
        var hook: (@Sendable (TimeInterval, SilentTrackDiagnostics.ProbeSnapshot) -> Void)?
        if silentTrackWatchdog {
            hook = { [weak self] afterSeconds, snapshot in
                self?.noteNoFirstBuffer(afterSeconds: afterSeconds, snapshot: snapshot)
            }
        }
        silentTrackDiagnostics.scheduleNoBufferProbes(processes, aggregateID: aggregateID, schedule: schedule, then: hook)
    }

    /// A no-first-buffer probe came back with the tap still silent (issue
    /// #693). Runs on the diagnostics queue, after the probe's own log line.
    /// The policy decides whether this probe opens a check at all; the
    /// reading it already took then concludes it, exactly as a zero-run
    /// check's own read does.
    private func noteNoFirstBuffer(afterSeconds: TimeInterval, snapshot: SilentTrackDiagnostics.ProbeSnapshot) {
        guard let (result, generation) = silentTrackDiagnostics.watchdogNoFirstBuffer(
            afterSeconds: afterSeconds, anyRunningOutput: Self.anyRunningOutput(in: snapshot), now: watchdogNow,
        ) else { return }
        act(on: result, snapshot: snapshot, generation: generation)
    }

    /// Decide on what the processes said. Runs on the diagnostics queue.
    private func concludeSilentTrackCheck(
        _ snapshot: SilentTrackDiagnostics.ProbeSnapshot, generation: Int,
    ) {
        guard let result = silentTrackDiagnostics.watchdogConclude(anyRunningOutput: Self.anyRunningOutput(in: snapshot))
        else { return }
        act(on: result, snapshot: snapshot, generation: generation)
    }

    /// A read that failed is not evidence of output. Conservative on
    /// purpose: the cost of a missed rebuild is the status quo, the cost of
    /// a wrong one is a restart exposed to issue #588.
    private static func anyRunningOutput(in snapshot: SilentTrackDiagnostics.ProbeSnapshot) -> Bool {
        snapshot.processes.contains { $0.isRunningOutput == .value(true) }
    }

    /// Log a check's outcome and, for a rebuild, hand it to the main queue.
    /// Runs on the diagnostics queue.
    private func act(
        on result: SilentTrackWatchdogPolicy.CheckResult, snapshot: SilentTrackDiagnostics.ProbeSnapshot, generation: Int,
    ) {
        // Formatted only by the arms that log; os_log evaluates the
        // interpolation lazily, so a declined check beyond the budget pays nothing.
        let what = { Self.describe(result.trigger) }
        let states = { snapshot.processes.map(\.summary).joined(separator: "; ") }
        switch result.decision {
        case let .declined(logged):
            guard logged else { return }
            let once = switch result.trigger {
            case .zeroRun: " (logged once per zero run)"
            case .noFirstBuffer: ""
            }
            logger.info(
                "App audio watchdog: \(what(), privacy: .public), isRunningOutput=false for all \(snapshot.processes.count, privacy: .public) tapped processes, not rebuilding\(once, privacy: .public)",
            )

        case .rebuild:
            logger.warning(
                "App audio watchdog: \(what(), privacy: .public), isRunningOutput=true, requesting a rebuild (\(result.unrecoveredStreak, privacy: .public) of \(SilentTrackWatchdogPolicy.maxUnrecoveredRebuilds, privacy: .public) so far in this run without signal) [\(states(), privacy: .public)]",
            )
            DispatchQueue.main.async { [weak self] in
                self?.rebuildSilentTap(judgedGeneration: generation)
            }

        case .giveUp:
            logger.error(
                "App audio watchdog: \(what(), privacy: .public), isRunningOutput=true, \(result.unrecoveredStreak, privacy: .public) rebuilds did not restore signal; not rebuilding again [\(states(), privacy: .public)]",
            )
            DispatchQueue.main.async { [weak self] in
                // A stop can land between the decision and this block; the
                // user is not told about a recording that already ended.
                guard let self, !self.silentTrackDiagnostics.watchdogStopped else { return }
                self.onSilentTrackWatchdogGaveUp?()
            }

        case .capReached:
            logger.warning(
                "App audio watchdog: \(what(), privacy: .public), \(SilentTrackWatchdogPolicy.maxRebuildsPerRecording, privacy: .public) rebuilds already in this recording; not rebuilding again",
            )
        }
    }

    /// Re-check, then run the rebuild through the device-change cycle. Main
    /// queue only, like every other restart.
    private func rebuildSilentTap(judgedGeneration: Int) {
        if let reason = silentTrackDiagnostics.watchdogBeginRebuild(
            liveSignalAges, judgedGeneration: judgedGeneration, captureRunning: isRunning, now: watchdogNow,
        ) {
            if silentTrackDiagnostics.watchdogClaimSkipLine() {
                logger.info("App audio watchdog: rebuild not started, \(Self.describe(reason), privacy: .public)")
            }
            return
        }
        let action = deviceChangeCoordinator.handle(.rebuildRequested)
        guard action != .ignore else {
            silentTrackDiagnostics.watchdogRebuildNotStarted()
            if silentTrackDiagnostics.watchdogClaimSkipLine() {
                logger.info("App audio watchdog: rebuild not started, a restart is already in progress")
            }
            return
        }
        let number = silentTrackDiagnostics.watchdogRebuildStarted(now: watchdogNow)
        logger.info(
            "App audio watchdog: rebuilding the tap on the current output device (rebuild \(number ?? 0, privacy: .public))",
        )
        applyAction(action)
    }

    /// Called by every tap installation, on the main queue. The watchdog
    /// keeps the time, which the re-check of a no-first-buffer rebuild reads.
    /// A tap installed while a watchdog rebuild waits for its verdict also
    /// restarts that rebuild's recovery window and gets a deadline of its
    /// own. The verdict comes from ticks, ticks only come with buffers, and a
    /// tap that starts without running an IO cycle (issue #693) delivers
    /// none, so without the deadline the rebuild would stay open until the
    /// recording stops. Armed per installation rather than at the rebuild's
    /// start, so the restart's own wait, retries and back-off are not charged
    /// to the tap, and a later installation's deadline replaces an earlier
    /// one's.
    func noteTapInstalledForWatchdog() {
        guard silentTrackWatchdog,
              let tap = silentTrackDiagnostics.watchdogRebuiltTapInstalled(now: watchdogNow)
        else { return }
        let deadline = SilentTrackWatchdogPolicy.rebuiltTapDeadlineSeconds
        silentTrackDiagnostics.scheduleWatchdogDeadline(after: deadline) { [weak self] in
            guard let self, let outcome = self.silentTrackDiagnostics.watchdogRebuiltTapDeadlinePassed(
                rebuild: tap.rebuild, install: tap.install, ages: self.liveSignalAges, now: self.watchdogNow,
            ) else { return }
            switch outcome {
            case let .stalled(rebuild, deliveredSinceInstall):
                let what = deliveredSinceInstall ? "stopped delivering buffers" : "delivered no buffer"
                logger.error(
                    "App audio watchdog: rebuild \(rebuild, privacy: .public) installed a tap that \(what, privacy: .public) within \(Self.seconds(deadline), privacy: .public) s; counted as not restoring signal",
                )

            case let .superseded(rebuild):
                Self.logSuperseded(rebuild)
            }
        }
    }

    /// Called by every output device change, on the main queue, before the
    /// restart path decides whether to act on it: a change it ignores, or one
    /// that lands while a restart has capture stopped, still moves the device
    /// the rebuild's tap is built on. Signal already back inside the window is
    /// credited to the rebuild; otherwise its verdict will be withheld.
    func noteOutputDeviceChangeForWatchdog() {
        guard silentTrackWatchdog,
              let outcome = silentTrackDiagnostics.watchdogOutputDeviceChanged(liveSignalAges, now: watchdogNow)
        else { return }
        switch outcome {
        case let .recovered(rebuild, withinSeconds):
            Self.logRecovered(rebuild, withinSeconds: withinSeconds)

        case let .tainted(rebuild):
            logger.info(
                "App audio watchdog: output device changed during rebuild \(rebuild, privacy: .public); it will close without a verdict",
            )
        }
    }

    /// Called when a tap is torn down, on the main queue: a tap on trial for
    /// a rebuild is no longer there to be judged.
    func noteTapRemovedForWatchdog() {
        guard silentTrackWatchdog else { return }
        silentTrackDiagnostics.watchdogRebuiltTapRemoved()
    }

    private static func logRecovered(_ rebuild: Int, withinSeconds: TimeInterval) {
        logger.info(
            "App audio watchdog: signal returned within \(seconds(withinSeconds), privacy: .public) s of rebuild \(rebuild, privacy: .public)",
        )
    }

    private static func logSuperseded(_ rebuild: Int) {
        logger.info(
            "App audio watchdog: rebuild \(rebuild, privacy: .public) closed without a verdict, the output device changed while it was open",
        )
    }

    /// Called from the restart path's two give-up points, on the main queue.
    /// A watchdog rebuild that was open when the restart gave up is what ended
    /// the channel, and that is the one outcome the evidence most needs.
    func noteRestartGaveUpForWatchdog() {
        guard let number = silentTrackDiagnostics.watchdogRestartGaveUp() else { return }
        logger.error(
            "App audio watchdog: rebuild \(number, privacy: .public) ended the channel, its restart gave up; not rebuilding again",
        )
    }

    /// The watchdog's clock: monotonic seconds, from the test seam if set.
    private var watchdogNow: TimeInterval {
        clockOverride?() ?? machTicksToSeconds(mach_absolute_time())
    }

    private static func describe(_ reason: SilentTrackWatchdogPolicy.Abandoned) -> String {
        switch reason {
        case .signalReturned: "signal returned before it could start"
        case .buffersStopped: "buffers stopped arriving"
        case .buffersArrived: "the first buffer arrived before it could start"
        case .tapReplaced: "another tap was installed meanwhile"
        case .captureNotRunning: "capture is not running"
        }
    }

    private static func describe(_ trigger: SilentTrackWatchdogPolicy.Trigger) -> String {
        switch trigger {
        case let .zeroRun(seconds): "exact zeros for \(Self.seconds(seconds)) s"
        case let .noFirstBuffer(afterSeconds): "no buffer \(Self.seconds(afterSeconds)) s after the device started"
        }
    }

    /// The watchdog's part of the `App audio at stop:` summary, or nil when it
    /// was off, in which case the summary is unchanged.
    var silentTrackWatchdogSummary: String? {
        silentTrackDiagnostics.watchdogCounters.map { counters in
            "watchdogChecks=\(counters.checks) watchdogNoFirstBufferChecks=\(counters.noFirstBufferChecks) "
                + "watchdogDeclined=\(counters.declined) "
                + "watchdogDropped=\(counters.dropped) watchdogRebuilds=\(counters.rebuilds) "
                + "watchdogRecoveries=\(counters.recoveries) watchdogGaveUp=\(counters.gaveUp) "
                + "watchdogCapped=\(counters.capped) watchdogEndedChannel=\(counters.endedChannel) "
                + "watchdogRebuiltTapStalled=\(counters.rebuiltTapStalled) watchdogSuperseded=\(counters.superseded)"
        }
    }
}
