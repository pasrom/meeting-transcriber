import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// Whether the microphone capture is getting anywhere. Main queue only, like
/// `session`.
///
/// Delivery is read by comparing the mach time of the last buffer with the
/// mach time the current epoch began. An age cannot answer "did anything
/// arrive since I armed" when the arming point moves on every adoption: at
/// five restarts a second the age of the last buffer is indistinguishable from
/// the age of no buffer at all. The times the policy weighs come from the
/// injected clock instead, so a test can drive them.
struct MicProgressState {
    /// Bumped whenever the watchdog is armed. A scheduled check carries the
    /// value it was armed with and does nothing if it no longer matches, so a
    /// timer from a superseded engine cannot judge its successor.
    var epoch = 0
    /// Mach time the current epoch began.
    var epochTicks: UInt64 = 0
    /// When the current epoch began, on the handler's clock.
    var epochStartedAt: TimeInterval = 0
    /// When the capture was last seen delivering, or when it started (or was
    /// revived) if it has not since. Moved only by an observed delivery.
    var lastKnownDeliveryAt: TimeInterval = 0
    /// Rebuilds the deadline ordered since the last delivery. Sets the next
    /// epoch's deadline, never the give-up.
    var rebuildsWithoutAudio = 0
    /// A revival has not delivered yet. Its first delivery reports the
    /// capture as resumed, so a revived engine that stays silent is never
    /// announced as back, and stalling again tells the user nothing new.
    var revivalAwaitingAudio = false
    /// Revivals since the capture last delivered; see
    /// `MicCaptureProgressPolicy.maxRevivalsWithoutAudio`.
    var revivalsWithoutAudio = 0
}

/// What a stall can say about itself, which decides what the user is told:
/// a microphone that never delivered did not "stop", and one whose revivals
/// have run out will not come back on a change of input.
public struct MicStallDetails: Equatable, Sendable {
    /// Whether the microphone delivered any buffer in this recording before
    /// it stalled.
    public var everDelivered: Bool
    /// Whether a change of the input may still start it again. False once
    /// `MicCaptureProgressPolicy.maxRevivalsWithoutAudio` revivals have
    /// brought no audio.
    public var mayRevive: Bool

    public init(everDelivered: Bool = true, mayRevive: Bool = true) {
        self.everDelivered = everDelivered
        self.mayRevive = mayRevive
    }
}

/// The end of one epoch, taken on the main queue before a restart's phase
/// flips back to capturing: whether the ending epoch delivered, and the mach
/// time the next one begins at. Taken there because from the flip on the new
/// engine's buffers are published too, and one landing before the adoption is
/// judged would otherwise be credited to the engine it replaced.
struct MicEpochHandover {
    let previousDelivered: Bool
    let boundary: UInt64
}

/// The progress watchdog (issues #724, #706).
///
/// Armed for as long as the capture runs, not only until the first buffer: an
/// engine that delivered and then stopped, with no configuration change to
/// say so, is the same fault seen later. Every epoch either sees a buffer, and
/// the next epoch is armed, or reaches its deadline, and the engine is rebuilt
/// with a longer deadline than the last. Once the capture has gone without a
/// buffer for the whole budget, across however many restarts and rebuilds, it
/// stalls: the engine is released, the file is kept, the user is told, and a
/// device change may start it again.
///
/// Rebuilds go through the `RestartArbiter` like every other restart, because
/// the attempt they could race may be wedged inside AVFAudio (issue #588), and
/// a second way to launch one would leak another thread into the same loop.
extension MicCaptureHandler {
    /// Called once the first engine is up.
    func beginProgressWatch() {
        progress.lastKnownDeliveryAt = clock()
        armProgressWatchdog(from: mach_absolute_time())
    }

    /// End the current epoch now. See `MicEpochHandover`.
    func endEpoch() -> MicEpochHandover {
        MicEpochHandover(previousDelivered: delivered(since: progress.epochTicks), boundary: mach_absolute_time())
    }

    /// What a stall now would say about itself.
    var stallDetails: MicStallDetails {
        MicStallDetails(
            everDelivered: lastBufferTicks != 0,
            mayRevive: progress.revivalsWithoutAudio < MicCaptureProgressPolicy.maxRevivalsWithoutAudio,
        )
    }

    /// Whether a stalled capture may be revived once more.
    var mayRevive: Bool {
        guard progress.revivalsWithoutAudio < MicCaptureProgressPolicy.maxRevivalsWithoutAudio else {
            logger.warning(
                "Mic: input device changed, but \(self.progress.revivalsWithoutAudio, privacy: .public) revivals delivered no audio; leaving the microphone released",
            )
            return false
        }
        return true
    }

    /// A device change is starting a stalled capture again. It gets a fresh
    /// budget, as a new recording would, and its first buffer bridges the
    /// stall in the track.
    func noteRevival() {
        logger.info("Mic: input device changed after the capture stalled, starting it again")
        armTimelineBridgeForRevival()
        progress.revivalAwaitingAudio = true
        progress.revivalsWithoutAudio += 1
        progress.lastKnownDeliveryAt = clock()
        progress.rebuildsWithoutAudio = 0
    }

    /// Judge the epoch the adoption ended, then start the next one, both as of
    /// `handover`, taken before the new engine could publish anything.
    ///
    /// Never stalls: the engine it adopts gets at least its first deadline,
    /// so a storm that settles just past the budget keeps the engine it
    /// settled on. A storm that goes on is ended at its next restart
    /// (`isSilentPastBudget`), and a silent engine at that deadline.
    func noteRestartAdopted(_ handover: MicEpochHandover) {
        if handover.previousDelivered { noteDelivery() }
        armProgressWatchdog(from: handover.boundary)
    }

    /// Whether the capture has gone the whole budget without audio, with
    /// nothing from the current engine either. Read where a storm would launch
    /// its next restart.
    var isSilentPastBudget: Bool {
        !delivered(since: progress.epochTicks)
            && MicCaptureProgressPolicy.isBudgetSpent(secondsWithoutAudio: secondsWithoutAudio)
    }

    /// The deadline for one epoch. Reaches a verdict only when no adoption beat
    /// it to it.
    func checkProgress(epoch: Int) {
        guard epoch == progress.epoch, isRecording else { return }
        let sinceEpoch = clock() - progress.epochStartedAt
        switch MicCaptureProgressPolicy.decide(
            secondsSinceEpoch: sinceEpoch,
            deliveredSinceEpoch: delivered(since: progress.epochTicks),
            rebuildsWithoutAudio: progress.rebuildsWithoutAudio,
            secondsWithoutAudio: secondsWithoutAudio,
        ) {
        case .healthy:
            noteDelivery()
            armProgressWatchdog(from: mach_absolute_time())

        case .waiting:
            // Reachable only if the timer fired early. Wait out the rest rather
            // than decide on a clock that has not run its course.
            scheduleProgressCheck(epoch: epoch, after: nextCheck(sinceEpoch: sinceEpoch))

        case .restart:
            guard case let .launchAttempt(generation) = arbiter.withLock({ state in
                state.handle(.progressDeadlineElapsed)
            }) else { return }
            logger.warning(
                "Mic: no buffer for \(Int(sinceEpoch), privacy: .public)s, rebuilding the engine (rebuild \(self.progress.rebuildsWithoutAudio + 1, privacy: .public) without audio)",
            )
            progress.rebuildsWithoutAudio += 1
            launchRestartAttempt(deviceUID: currentRestartTarget(), generation: generation)

        case .giveUp:
            stallSilentCapture()
        }
    }

    /// How a failed restart is retried: by the retry schedule's count for a
    /// restart a device change launched, as before the watchdog, and by the
    /// budget for a rebuild or revival (`MicCaptureProgressPolicy.retry`).
    func restartRetryAction() -> CaptureRestartRetryAction {
        let scheduled = decideRetry(restartRetryCount)
        guard arbiter.withLock({ $0.retriesUntilBudgetSpent }) else { return scheduled }
        return MicCaptureProgressPolicy.retry(
            scheduled,
            budgetLeft: MicCaptureProgressPolicy.maxSecondsWithoutAudio - secondsWithoutAudio,
        )
    }

    private var secondsWithoutAudio: TimeInterval {
        clock() - progress.lastKnownDeliveryAt
    }

    /// Seconds until this epoch next needs judging: its deadline, or the end
    /// of the budget if that comes first, so a long late deadline cannot carry
    /// a silent capture past the budget. Never less than the first deadline
    /// into the epoch, so every engine gets that long to deliver.
    ///
    /// And never less than `MicCaptureProgressPolicy.minimumRecheck`: a check
    /// that fires a rounding error before its deadline finds the rest of the
    /// wait to be that rounding error, and a timer for it is due at once,
    /// again and again.
    private func nextCheck(sinceEpoch: TimeInterval) -> TimeInterval {
        let deadline = MicCaptureProgressPolicy.bufferDeadline(afterRebuilds: progress.rebuildsWithoutAudio)
        let budgetLeft = MicCaptureProgressPolicy.maxSecondsWithoutAudio - secondsWithoutAudio
        let floor = MicCaptureProgressPolicy.firstBufferDeadline - sinceEpoch
        return max(min(deadline - sinceEpoch, max(budgetLeft, floor)), MicCaptureProgressPolicy.minimumRecheck)
    }

    /// Whether a buffer was published after `start`.
    private func delivered(since start: UInt64) -> Bool {
        lastBufferTicks > start
    }

    /// Delivery clears the debt: a capture that recovered after a storm, a
    /// rebuild or a revival starts its budget, its deadlines and its revivals
    /// afresh.
    ///
    /// Credited at the last buffer's own time, not at the moment it is
    /// noticed, which may be a whole deadline later: the buffer's age on the
    /// mach clock is taken off the handler's clock. Both exclude sleep.
    private func noteDelivery() {
        let age = machTicksToSeconds(mach_absolute_time()) - machTicksToSeconds(lastBufferTicks)
        progress.lastKnownDeliveryAt = clock() - max(age, 0)
        progress.rebuildsWithoutAudio = 0
        progress.revivalsWithoutAudio = 0
        if progress.revivalAwaitingAudio {
            progress.revivalAwaitingAudio = false
            onResume?()
        }
    }

    private func armProgressWatchdog(from boundary: UInt64) {
        progress.epoch += 1
        progress.epochTicks = boundary
        progress.epochStartedAt = clock()
        scheduleProgressCheck(epoch: progress.epoch, after: nextCheck(sinceEpoch: 0))
    }

    private func scheduleProgressCheck(epoch: Int, after delay: TimeInterval) {
        scheduleOnMain(delay) { [weak self] in
            self?.checkProgress(epoch: epoch)
        }
    }

    /// Release the engine and tell the user, keeping the file for a revival.
    ///
    /// Unlike the two give-ups of the restart path, nothing is in flight here:
    /// the arbiter only allows it from `.capturing`, so the current engine is
    /// idle with its tap installed and can be torn down on this queue, as a
    /// rebuild would. It has to be, because a running engine keeps the input
    /// open for the rest of the recording, which holds a Bluetooth headset in
    /// its call profile after the user was told the microphone is lost.
    func stallSilentCapture() {
        guard case .stall = arbiter.withLock({ $0.handle(.progressBudgetExhausted) }) else { return }
        logger.error(
            "Mic: no audio for \(Int(self.secondsWithoutAudio), privacy: .public)s across \(self.progress.rebuildsWithoutAudio, privacy: .public) rebuilds, releasing the microphone until the input device changes",
        )
        removeConfigChangeObserver()
        session.teardown()
        onStall?(stallDetails)
    }
}
