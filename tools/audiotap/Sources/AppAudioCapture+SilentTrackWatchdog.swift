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
/// **Same anchor, same path.** The rebuild goes through
/// `OutputDeviceChangeCoordinator` and `applyAction`, so it gets a fresh
/// `AppTapSession` built by `startCapture()` on the current default output
/// device, a generation-tagged attempt bounded by `RestartArbiter`'s deadline,
/// the shared `CaptureRestartRetryPolicy` budget, and `TimelineAnchor` turning
/// the gap into silence. Nothing here picks a different device.
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
            logger.info(
                "App audio watchdog: signal returned within \(Self.seconds(withinSeconds), privacy: .public) s of rebuild \(rebuild, privacy: .public)",
            )

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
            // A read still outstanding. The sink has already said so, and the
            // policy waits out the interval before asking again.
            if !started {
                silentTrackDiagnostics.watchdogAbandonCheck()
            }
        }
    }

    /// Decide on what the processes said. Runs on the diagnostics queue.
    private func concludeSilentTrackCheck(
        _ snapshot: SilentTrackDiagnostics.ProbeSnapshot, generation: Int,
    ) {
        // A read that failed is not evidence of output. Conservative on
        // purpose: the cost of a missed rebuild is the status quo, the cost of
        // a wrong one is a restart exposed to issue #588.
        let running = snapshot.processes.contains { $0.isRunningOutput == .value(true) }
        guard let result = silentTrackDiagnostics.watchdogConclude(anyRunningOutput: running)
        else { return }

        // Formatted only by the arms that log; os_log evaluates the
        // interpolation lazily, so a declined check beyond the budget pays nothing.
        let zeroRun = { Self.seconds(result.zeroRunSeconds) }
        let states = { snapshot.processes.map(\.summary).joined(separator: "; ") }
        switch result.decision {
        case let .declined(logged):
            guard logged else { return }
            logger.info(
                "App audio watchdog: exact zeros for \(zeroRun(), privacy: .public) s, isRunningOutput=false for all \(snapshot.processes.count, privacy: .public) tapped processes, not rebuilding (logged once per zero run)",
            )

        case .rebuild:
            logger.warning(
                "App audio watchdog: exact zeros for \(zeroRun(), privacy: .public) s, isRunningOutput=true, requesting a rebuild (\(result.unrecoveredStreak, privacy: .public) of \(SilentTrackWatchdogPolicy.maxUnrecoveredRebuilds, privacy: .public) so far in this run without signal) [\(states(), privacy: .public)]",
            )
            DispatchQueue.main.async { [weak self] in
                self?.rebuildSilentTap(judgedGeneration: generation)
            }

        case .giveUp:
            logger.error(
                "App audio watchdog: exact zeros for \(zeroRun(), privacy: .public) s, isRunningOutput=true, \(result.unrecoveredStreak, privacy: .public) rebuilds did not restore signal; not rebuilding again [\(states(), privacy: .public)]",
            )
            DispatchQueue.main.async { [weak self] in
                // A stop can land between the decision and this block; the
                // user is not told about a recording that already ended.
                guard let self, !self.silentTrackDiagnostics.watchdogStopped else { return }
                self.onSilentTrackWatchdogGaveUp?()
            }

        case .capReached:
            logger.warning(
                "App audio watchdog: exact zeros for \(zeroRun(), privacy: .public) s, \(SilentTrackWatchdogPolicy.maxRebuildsPerRecording, privacy: .public) rebuilds already in this recording; not rebuilding again",
            )
        }
    }

    /// Re-check, then run the rebuild through the device-change cycle. Main
    /// queue only, like every other restart.
    private func rebuildSilentTap(judgedGeneration: Int) {
        if let reason = silentTrackDiagnostics.watchdogBeginRebuild(
            liveSignalAges, judgedGeneration: judgedGeneration, captureRunning: isRunning,
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
        case .tapReplaced: "another tap was installed meanwhile"
        case .captureNotRunning: "capture is not running"
        }
    }

    /// The watchdog's part of the `App audio at stop:` summary, or nil when it
    /// was off, in which case the summary is unchanged.
    var silentTrackWatchdogSummary: String? {
        silentTrackDiagnostics.watchdogCounters.map { counters in
            "watchdogChecks=\(counters.checks) watchdogDeclined=\(counters.declined) "
                + "watchdogDropped=\(counters.dropped) watchdogRebuilds=\(counters.rebuilds) "
                + "watchdogRecoveries=\(counters.recoveries) watchdogGaveUp=\(counters.gaveUp) "
                + "watchdogCapped=\(counters.capped) watchdogEndedChannel=\(counters.endedChannel)"
        }
    }
}
