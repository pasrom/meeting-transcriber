import Foundation

/// Decides when a run of exact zeros on the app track is worth rebuilding the
/// tap for, how often, whether a rebuild helped, and when to stop trying
/// (issue #672, part 2).
///
/// `SilentTrackObserver` is the sensor: it logs when the track enters and
/// leaves a zero run. This is the actuator's judgement, and it is opt-in,
/// because the case for acting is weaker than the case for logging. Two of the
/// three readings of the field case mean a rebuild changes nothing, and every
/// rebuild is an exposure to the wedge class of issue #588, which is terminal
/// for the channel. What the watchdog buys is evidence either way, so the
/// numbers it reports have to mean what they say: a recovery is credited only
/// when signal returns right after a rebuild, not whenever someone speaks.
///
/// Three steps, because the inputs live on three queues:
/// - `tick` (write queue) says a check is due, and closes a started rebuild
///   as recovered or not once its window has passed;
/// - `conclude` (diagnostics queue) decides on the tapped processes'
///   `kAudioProcessPropertyIsRunningOutput`, read off the write queue;
/// - `beginRebuild`, then `rebuildStarted` or `rebuildNotStarted` (main
///   queue), re-check the decision against the present before acting, and
///   count only a rebuild the restart path actually took.
///
/// Pure, with the clock passed in (monotonic seconds), following
/// `RestartArbiter` and `CaptureRestartRetryPolicy`.
struct SilentTrackWatchdogPolicy: Equatable {
    /// How long the track must have been at exact zeros, with buffers still
    /// arriving, before a rebuild is considered.
    ///
    /// Deliberately not aggressive. A rebuild costs at least the half second
    /// the restart path waits before rebuilding plus the rebuild itself, which
    /// lands as silence, and a legitimately silent far end reaches this state
    /// too. Sixty seconds because:
    ///
    /// - it is six times the observer's 10 s logging threshold, so every
    ///   action is preceded by a logged run it can be read against;
    /// - it is under the 90 s default of the "Warn after" setting, so a
    ///   rebuild that works lands before the user is told the channel is
    ///   silent, rather than after;
    /// - the audio a false positive costs sits inside a minute of zeros, so
    ///   it is most likely silence itself;
    /// - the field cases this exists for ran 1193 s and 2765 s at exact zeros,
    ///   so waiting a minute costs a small share of what they lost, while a
    ///   shorter window would multiply the #588 exposure across ordinary
    ///   stretches of silence in every call.
    ///
    /// A low non-zero floor is out of scope: it never counts as a zero run.
    static let triggerZeroRunSeconds = SilentTrackWatchdogLimits.secondsOfZerosBeforeRebuild

    /// At most one check, and so at most one rebuild, per this many seconds,
    /// counted from the last check whether it rebuilt or not.
    static let minSecondsBetweenChecks = SilentTrackWatchdogLimits.secondsBetweenRebuilds

    /// Rebuilds in one zero run that did not bring signal back before the
    /// watchdog stops and says so. The run ends, and the budget refills, when
    /// signal returns, whether a rebuild brought it or not.
    static let maxUnrecoveredRebuilds = SilentTrackWatchdogLimits.rebuildsWithoutSignal

    /// How soon after the rebuilt tap is installed non-zero signal must be
    /// seen for the rebuild to be credited with it. Counted from the
    /// installation, see `rebuiltTapInstalled`; from the rebuild's start only
    /// until one happens.
    ///
    /// A restored tap delivers at once: a fresh aggregate's first callback
    /// takes 30 to 60 ms, 0.78 s at the slowest on record, and before the
    /// installation the restart path waits 0.5 s and bounds a successful
    /// attempt by `RestartArbiter.attemptTimeout` (5 s). Ten seconds covers
    /// the callback with a wide margin, while staying a sixth of the trigger
    /// window, so a participant who resumes speaking a minute later is not
    /// counted as a rebuild that worked. The signal has to have arrived inside
    /// the window, however late the tick that sees it; see `tick`.
    static let recoveryWindowSeconds: TimeInterval = 10

    /// How long after its installation a rebuilt tap's deadline closes a
    /// rebuild no tick has judged. Two report intervals past the window: the
    /// first tick that can judge comes once the window has passed, on the
    /// first buffer at least one report interval after the previous tick, so
    /// a tap whose buffers never pause for about a report interval around the
    /// end of the window is judged by a tick first. That is what lets the
    /// deadline do without a first-buffer signal from the IO callback: what it
    /// still finds open had no tick to judge it, or buffers paused that long.
    static let rebuiltTapDeadlineSeconds = recoveryWindowSeconds + 2 * DebugRMSReporter.reportIntervalSeconds

    /// Rebuilds per recording, however often the budget refills. Each one is
    /// an exposure to the restart wedge of issue #588, which ends the channel
    /// for the rest of the recording, and refills are exactly what a far end
    /// that falls silent for minutes at a time produces. Six is two full
    /// budgets: enough to show a pattern in the log, few enough that a
    /// recording in which rebuilding keeps "working" is not rebuilt without
    /// end.
    static let maxRebuildsPerRecording = SilentTrackWatchdogLimits.rebuildsPerRecording

    /// Lines per recording for checks that did not rebuild (declined, skipped
    /// behind another probe's outstanding read, or a request dropped on
    /// re-check). Rebuild lines need no budget of their own: the total cap
    /// bounds them.
    static let maxLoggedSkips = 20

    struct Counters: Equatable {
        /// Checks opened: zero run past the window, buffers arriving, rate
        /// limit clear.
        var checks = 0
        /// Checks at which no tapped process reported output.
        var declined = 0
        /// Rebuilds the restart path actually started.
        var rebuilds = 0
        /// Rebuilds after which signal returned inside the recovery window.
        var recoveries = 0
        /// Checks that ended without a decision or a rebuild: the probe was
        /// busy, the request was dropped on its re-check, or the restart path
        /// refused it. With these, `checks` equals declined + rebuilds +
        /// dropped + the give-up + the cap + a check still open.
        var dropped = 0
        var gaveUp = false
        /// Stopped at `maxRebuildsPerRecording`.
        var capped = false
        /// A watchdog rebuild's restart gave up (retry budget, or an attempt
        /// that never returned, issue #588) and the channel ended with it.
        var endedChannel = false
        /// Rebuilds closed by their tap's deadline because no tick judged
        /// them: the tap delivered no buffer (the failure of issue #693), or
        /// stopped delivering before a tick could. Each also counts as
        /// unrecovered.
        var rebuiltTapStalled = 0
        /// Rebuilds closed without a verdict because an output device changed
        /// while they were open: what a tap built after that does is the
        /// device change's as much as theirs. Not strikes: none of these
        /// counts toward the give-up.
        var superseded = 0
    }

    enum TickEvent: Equatable {
        /// Non-zero signal arrived inside rebuild `rebuild`'s recovery window.
        /// `withinSeconds` is when the latest non-zero sample the judging
        /// tick saw arrived, relative to the start of the window: an upper
        /// bound on when signal first came back.
        case recovered(rebuild: Int, withinSeconds: TimeInterval)
        /// The recovery window passed with the track still at zeros.
        case unrecovered(rebuild: Int, afterSeconds: TimeInterval)
        /// Ask the tapped processes whether any still reports output, then
        /// call `conclude`.
        case check(zeroRunSeconds: TimeInterval)
        /// The rebuild's verdict was due, but an output device change during
        /// it took the verdict away; closed without one.
        case superseded(rebuild: Int)
    }

    /// How a rebuilt tap's deadline closed its rebuild.
    enum DeadlineOutcome: Equatable {
        /// No tick judged it. `deliveredSinceInstall` says whether the tap
        /// delivered any buffer before it stalled.
        case stalled(rebuild: Int, deliveredSinceInstall: Bool)
        /// An output device change during it took the verdict away.
        case superseded(rebuild: Int)
    }

    /// What an output device change did to an open rebuild.
    enum DeviceChangeOutcome: Equatable {
        /// Signal had already come back inside the window: the rebuild's.
        case recovered(rebuild: Int, withinSeconds: TimeInterval)
        /// Whatever happens next is the device change's as much as the
        /// rebuild's, so its verdict will be withheld.
        case tainted(rebuild: Int)
    }

    enum Decision: Equatable {
        /// No tapped process reports output, so the zeros are explained
        /// without the tap being at fault. `logged` says whether this decline
        /// is inside the log budget.
        case declined(logged: Bool)
        /// Ask the main queue to rebuild; see `beginRebuild`.
        case rebuild
        /// The zero run's budget is spent. Stop for the rest of the recording
        /// and tell the user, once.
        case giveUp
        /// The recording's total cap is reached. Stop, without a verdict on
        /// the tap: the last rebuild may well have worked.
        case capReached
    }

    struct CheckResult: Equatable {
        let zeroRunSeconds: TimeInterval
        let decision: Decision
        /// Rebuilds in this zero run that have not restored signal.
        let unrecoveredStreak: Int
    }

    /// Why a requested rebuild was dropped on re-check.
    enum Abandoned: Equatable {
        case signalReturned
        case buffersStopped
        case tapReplaced
        /// Capture stopped, or is between a restart's stop and its adoption.
        /// Also the answer when no request is open, which only a stop causes.
        case captureNotRunning
    }

    /// Where the watchdog is between ticks. One value rather than three
    /// optionals, so "a check and a rebuild open at once" cannot be written.
    private enum Phase: Equatable {
        case idle
        /// A check waiting for `conclude`, with the zero run it was opened on.
        case checking(zeroRun: TimeInterval)
        /// A rebuild requested and not yet started or dropped.
        case requested
        /// A rebuild started and waiting for its verdict. `startedAt` opens
        /// its recovery window: the rebuild's start, then the installation of
        /// each tap put on trial for it.
        case rebuilding(number: Int, startedAt: TimeInterval)
    }

    private(set) var counters = Counters()
    private(set) var unrecoveredStreak = 0
    private var phase = Phase.idle
    private var lastCheckAt: TimeInterval?
    private var skipLinesLogged = 0
    private var declineLoggedThisRun = false
    /// Taps installed across the recording while a rebuild was open, so a
    /// deadline can name the one it was armed for.
    private var tapsInstalled = 0
    /// The installation on trial for the open rebuild, nil while none is
    /// installed (before the first, or after a tap was torn down).
    private var tapOnTrial: Int?
    /// An output device changed while the open rebuild waited for its
    /// verdict; see `outputDeviceChanged`.
    private var rebuildTainted = false
    private(set) var stopped = false

    /// Whether one more line for a skipped check fits the budget. Never after
    /// a stop, so nothing is logged behind the stop summary.
    mutating func claimSkipLine() -> Bool {
        guard !stopped, skipLinesLogged < Self.maxLoggedSkips else { return false }
        skipLinesLogged += 1
        return true
    }

    mutating func tick(_ ages: ChannelSignalAges, now: TimeInterval) -> TickEvent? {
        guard !stopped else { return nil }
        // The tap that was never allowed to hear the app (issue #524).
        guard let energyAge = ages.secondsSinceLastEnergy else { return nil }

        // A started rebuild is judged first, and nothing else happens while
        // its window is open. The level publisher outlives the tap, so an
        // energy age reaching back before the window is the old run growing.
        //
        // What decides is when the signal arrived, not when a tick saw it:
        // ticks only come with buffers, so after a slow or backed-off restart
        // the first one can land long after the window, and speech it sees
        // then is a participant, not the rebuild. The age measures the latest
        // non-zero sample, so a restored tap that kept delivering would read
        // as late too; it cannot happen, since a delivering tap ticks every
        // 5 s and is judged inside the window.
        if case let .rebuilding(number, startedAt) = phase {
            let within = Self.signalInWindow(signalAt: now - energyAge, windowStart: startedAt)
            guard within != nil || now - startedAt >= Self.recoveryWindowSeconds else { return nil }
            // An output device change during the rebuild took the verdict
            // away; signal from before it was already credited then.
            if rebuildTainted {
                closeWithoutVerdict()
                return .superseded(rebuild: number)
            }
            if let within {
                closeRecovered()
                return .recovered(rebuild: number, withinSeconds: within)
            }
            phase = .idle
            tapOnTrial = nil
            return .unrecovered(rebuild: number, afterSeconds: now - startedAt)
        }

        // Signal inside the last trigger window means the zero run ended. The
        // budget is per run, so it refills here, a decline in between or not.
        if energyAge < Self.triggerZeroRunSeconds {
            unrecoveredStreak = 0
            declineLoggedThisRun = false
        }

        guard phase == .idle, !counters.gaveUp, !counters.capped, !counters.endedChannel,
              let zeroRun = ages.zeroRunWhileBuffersArrive,
              zeroRun >= Self.triggerZeroRunSeconds
        else { return nil }
        if let lastCheckAt, now - lastCheckAt < Self.minSecondsBetweenChecks { return nil }

        lastCheckAt = now
        phase = .checking(zeroRun: zeroRun)
        counters.checks += 1
        return .check(zeroRunSeconds: zeroRun)
    }

    /// Close the open check with what the tapped processes said. Nil when no
    /// check is open, which includes every check `stop()` dropped.
    mutating func conclude(anyRunningOutput: Bool) -> CheckResult? {
        guard case let .checking(zeroRun) = phase else { return nil }
        phase = .idle

        let decision: Decision
        if !anyRunningOutput {
            counters.declined += 1
            let logged = !declineLoggedThisRun && claimSkipLine()
            if logged { declineLoggedThisRun = true }
            decision = .declined(logged: logged)
        } else if unrecoveredStreak >= Self.maxUnrecoveredRebuilds {
            counters.gaveUp = true
            decision = .giveUp
        } else if counters.rebuilds >= Self.maxRebuildsPerRecording {
            counters.capped = true
            decision = .capReached
        } else {
            phase = .requested
            decision = .rebuild
        }
        return CheckResult(zeroRunSeconds: zeroRun, decision: decision, unrecoveredStreak: unrecoveredStreak)
    }

    /// Re-check a requested rebuild against the present, on the main queue,
    /// right before acting. Nil means go ahead, leaving the request open for
    /// `rebuildStarted` or `rebuildNotStarted`; a reason drops it.
    mutating func beginRebuild(_ ages: ChannelSignalAges, sameTap: Bool, captureRunning: Bool) -> Abandoned? {
        guard phase == .requested else { return .captureNotRunning }
        let reason: Abandoned? = if !captureRunning {
            .captureNotRunning
        } else if !sameTap {
            .tapReplaced
        } else if let zeroRun = ages.zeroRunWhileBuffersArrive {
            zeroRun < Self.triggerZeroRunSeconds ? .signalReturned : nil
        } else {
            .buffersStopped
        }
        if reason != nil {
            phase = .idle
            counters.dropped += 1
        }
        return reason
    }

    /// The restart path took the rebuild. Counted, and its recovery window
    /// opened, from now, until its tap is installed. Returns the rebuild's
    /// number in this recording.
    @discardableResult
    mutating func rebuildStarted(now: TimeInterval) -> Int {
        counters.rebuilds += 1
        unrecoveredStreak += 1
        tapOnTrial = nil
        rebuildTainted = false
        phase = .rebuilding(number: counters.rebuilds, startedAt: now)
        return counters.rebuilds
    }

    /// The restart path refused (a restart was already in flight). Nothing
    /// was rebuilt, so nothing is counted or opened.
    mutating func rebuildNotStarted() {
        phase = .idle
        counters.dropped += 1
    }

    /// The restart path gave up. If a watchdog rebuild was open, that rebuild
    /// ended the channel: record it, stop the watchdog, and return its number
    /// for the log. Nil when none was open, which makes it a device change's
    /// give-up and none of the watchdog's business.
    mutating func restartGaveUp() -> Int? {
        guard case let .rebuilding(number, _) = phase else { return nil }
        phase = .idle
        tapOnTrial = nil
        counters.endedChannel = true
        return number
    }

    /// A tap was installed while a rebuild waits for its verdict: put it on
    /// trial. Its recovery window starts now, not at the rebuild's start, so
    /// a restart that waited or backed off for longer than the window does not
    /// cost a rebuild that worked; nothing ticks before an installation, since
    /// ticks come with the buffers of an installed tap. Returns what its
    /// deadline must name, or nil when no rebuild is open. `now` is only read
    /// when one is.
    ///
    /// One rebuild's restart can install more than once (a start reporting
    /// rate 0 is retried), and only the tap installed last is on trial: the
    /// verdict is about the tap that is there.
    mutating func rebuiltTapInstalled(now: () -> TimeInterval) -> (rebuild: Int, install: Int)? {
        guard !stopped, case let .rebuilding(number, _) = phase else { return nil }
        tapsInstalled += 1
        tapOnTrial = tapsInstalled
        phase = .rebuilding(number: number, startedAt: now())
        return (number, tapsInstalled)
    }

    /// The tap on trial was torn down (a retry, a device change, a stop).
    /// Its deadline has nothing left to judge; the rebuild stays open for
    /// the next installation or the restart's give-up.
    mutating func rebuiltTapRemoved() {
        tapOnTrial = nil
    }

    /// The deadline armed for installation `install` of rebuild `rebuild` has
    /// passed. Closes the rebuild only if that tap is still installed and no
    /// tick judged it first; nil otherwise.
    ///
    /// Needed because ticks only come with buffers. A tap that starts without
    /// running an IO cycle (issue #693), or stops before a tick could judge
    /// it, never ticks, so without this the rebuild would wait for a verdict
    /// until the recording stops. Closed, not stopped: the rebuild already
    /// counts against the run's budget, and if buffers come back later the
    /// watchdog carries on from there. A buffer newer than the installation
    /// is the tap's own: the previous tap's write queue was drained first.
    mutating func rebuiltTapDeadlinePassed(
        rebuild: Int, install: Int, ages: ChannelSignalAges, now: TimeInterval,
    ) -> DeadlineOutcome? {
        guard !stopped, case let .rebuilding(number, installedAt) = phase, number == rebuild,
              tapOnTrial == install
        else { return nil }
        if rebuildTainted {
            closeWithoutVerdict()
            return .superseded(rebuild: number)
        }
        phase = .idle
        tapOnTrial = nil
        counters.rebuiltTapStalled += 1
        let delivered = ages.secondsSinceLastBuffer.map { now - $0 > installedAt } ?? false
        return .stalled(rebuild: number, deliveredSinceInstall: delivered)
    }

    /// An output device changed while a rebuild is open, whether or not the
    /// restart path acts on it: the rebuild's next tap is built on the new
    /// device either way. Signal already back inside the window is the
    /// rebuild's and is credited now; otherwise the rebuild's verdict will be
    /// withheld when it is due. Nil when no rebuild is open.
    mutating func outputDeviceChanged(_ ages: ChannelSignalAges, now: TimeInterval) -> DeviceChangeOutcome? {
        guard !stopped, case let .rebuilding(number, startedAt) = phase else { return nil }
        if let energyAge = ages.secondsSinceLastEnergy, let within = Self.signalInWindow(
            signalAt: now - energyAge, windowStart: startedAt,
        ) {
            closeRecovered()
            return .recovered(rebuild: number, withinSeconds: within)
        }
        rebuildTainted = true
        return .tainted(rebuild: number)
    }

    /// Seconds into the window at which signal arrived, or nil when it
    /// arrived before the window or after it.
    private static func signalInWindow(signalAt: TimeInterval, windowStart: TimeInterval) -> TimeInterval? {
        guard signalAt > windowStart, signalAt - windowStart <= recoveryWindowSeconds else { return nil }
        return signalAt - windowStart
    }

    private mutating func closeRecovered() {
        phase = .idle
        tapOnTrial = nil
        unrecoveredStreak = 0
        counters.recoveries += 1
    }

    /// A verdict withheld is not a strike: the bump `rebuildStarted` made is
    /// taken back, so device changes during rebuilds, which is what the app
    /// advises, never add up to a give-up.
    private mutating func closeWithoutVerdict() {
        phase = .idle
        tapOnTrial = nil
        rebuildTainted = false
        unrecoveredStreak = max(0, unrecoveredStreak - 1)
        counters.superseded += 1
    }

    /// The processes could not be asked, because an earlier read is still
    /// inside coreaudiod. Close the check without a decision; the rate limit
    /// stays where the check put it, since rebuilding while the HAL is not
    /// answering is exactly the exposure issue #588 is about.
    mutating func abandonCheck() {
        guard case .checking = phase else { return }
        phase = .idle
        counters.dropped += 1
    }

    /// The recording stopped. Everything still in flight is dropped, so no
    /// counter moves and no line is written after the stop summary.
    mutating func stop() {
        stopped = true
        phase = .idle
    }
}
