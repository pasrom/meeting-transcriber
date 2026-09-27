import Foundation

/// What a microphone capture that has not delivered should do next.
enum MicCaptureProgress: Equatable {
    /// A buffer arrived since the current epoch. Nothing to do.
    case healthy
    /// No buffer yet, but neither the deadline nor the budget has run out.
    case waiting
    /// The deadline passed with no buffer. Rebuild the engine.
    case restart
    /// The capture has gone without audio for the whole budget. Release it and
    /// tell the user.
    case giveUp
}

/// Whether a microphone capture is getting anywhere, and what to do when it is
/// not.
///
/// An epoch starts when an engine comes up, and again whenever a restart is
/// adopted or a delivering capture is checked. Two arms, because the fault has
/// two shapes and each is invisible to the other's test. Both come from one
/// field recording (issue #724); a second report has the first on a USB
/// speakerphone (issue #706), so neither is specific to one transport.
///
/// **The silent stable engine.** After a restart loop ended, the capture sat
/// for 48 minutes having logged `Mic recording started`, with no configuration
/// change and no buffer. Nothing restarts there, so only a deadline sees it,
/// and what it orders is a rebuild, since a fresh engine is the one thing that
/// could revive it.
///
/// **The storm.** A configuration change restarts the engine, the engine comes
/// up, and the next change arrives before a single buffer does, about five
/// times a second. Every adoption starts a new epoch, so the deadline never
/// elapses. What grows is the time since the capture last delivered, and that
/// is what ends it.
///
/// **Only time gives up, never a count.** In the same report the built-in
/// microphone ran the identical storm, 78 restarts in 14 seconds, and then
/// delivered a complete track; a budget counted in restarts ends that track in
/// its first second. And a Bluetooth headset whose first buffer takes a little
/// over the first deadline, because opening the input is what flips it into
/// its call profile, would be rebuilt on the same clock until any count ran
/// out. So each rebuild gets a longer deadline than the last, and the give-up
/// is the time without audio alone.
enum MicCaptureProgressPolicy {
    /// How long a fresh engine may go without its first buffer before it is
    /// rebuilt.
    ///
    /// Measured rather than chosen. `DebugRMSReporter.tick` starts its five
    /// second interval on the *first buffer*, so the gap between
    /// `Mic recording started` and the first `Mic RMS (5s)` line is five
    /// seconds plus the wait for that first buffer. Across 16 healthy
    /// recordings in the field logs that gap was 5.0 s at the median and 6.0 s
    /// at the worst, which puts the first buffer inside a second of the start
    /// every time. Firing early costs a rebuild, not a recording, and the next
    /// deadline is longer.
    static let firstBufferDeadline: TimeInterval = 3

    /// The longest any one epoch is given. Four doublings of the first.
    static let maxBufferDeadline: TimeInterval = 24

    /// How long a capture may go without a single buffer, across however many
    /// restarts and rebuilds, before it is given up.
    ///
    /// Four times the one healthy storm on record (14 s), and a sixth of the
    /// 5.6 minute storm that never delivered. A silent engine is rebuilt at 3,
    /// 9, 21 and 45 seconds and given up at 60, so the user hears about it in
    /// the first minute of the meeting rather than after it.
    static let maxSecondsWithoutAudio: TimeInterval = 60

    /// The deadline for an epoch that follows `rebuilds` rebuilds without
    /// audio: 3, 6, 12, 24, 24, ... seconds.
    static func bufferDeadline(afterRebuilds rebuilds: Int) -> TimeInterval {
        min(firstBufferDeadline * pow(2, Double(min(max(rebuilds, 0), 8))), maxBufferDeadline)
    }

    /// The shortest wait before an epoch is judged again. Only reached by a
    /// check that fired a hair before its deadline; long enough that the
    /// clock has moved when it fires, short enough that no verdict is late
    /// by anything a user could notice.
    static let minimumRecheck: TimeInterval = 0.01

    /// Whether the capture has gone without audio for the whole budget.
    static func isBudgetSpent(secondsWithoutAudio: TimeInterval) -> Bool {
        secondsWithoutAudio >= maxSecondsWithoutAudio
    }

    /// How a failed rebuild or revival is retried, given what the restart
    /// retry schedule would do (`scheduled`) and how much of the budget is
    /// left.
    ///
    /// On the schedule's backoff while it has steps left, then on its longest
    /// step, and given up at the first failure once the budget is spent. The
    /// budget is read when a failed attempt returns, so the stall can land up
    /// to one step plus one attempt past it, and an attempt may run until the
    /// attempt deadline before it throws: about 7 s at most while the main
    /// queue keeps up. Its count alone would release a microphone
    /// about nine seconds into a recording whenever an engine throws for
    /// longer than the schedule runs, which is what a headset changing
    /// profile can do, and only time gives up. Not shortened to land on the
    /// end of the budget: the remainder can come out as a rounding error, and
    /// a retry due after it is a retry due now, again and again.
    static func retry(
        _ scheduled: CaptureRestartRetryAction,
        budgetLeft: TimeInterval,
    ) -> CaptureRestartRetryAction {
        guard budgetLeft > 0 else { return .giveUp }
        return switch scheduled {
        case .retry: scheduled
        case .giveUp: .retry(afterSeconds: CaptureRestartRetryPolicy.maxBackoff)
        }
    }

    /// - Parameters:
    ///   - secondsSinceEpoch: since the current epoch began.
    ///   - deliveredSinceEpoch: whether a buffer arrived after that. Not
    ///     "ever": a restart inheriting an older buffer's credit would never be
    ///     judged at all.
    ///   - rebuildsWithoutAudio: rebuilds the deadline ordered since the
    ///     capture last delivered; sets this epoch's deadline.
    ///   - secondsWithoutAudio: since the capture last delivered, or since it
    ///     started if it never has.
    static func decide(
        secondsSinceEpoch: TimeInterval,
        deliveredSinceEpoch: Bool,
        rebuildsWithoutAudio: Int,
        secondsWithoutAudio: TimeInterval,
    ) -> MicCaptureProgress {
        if deliveredSinceEpoch { return .healthy }
        // Before the deadline, because in the storm the deadline never arrives.
        if isBudgetSpent(secondsWithoutAudio: secondsWithoutAudio) { return .giveUp }
        return secondsSinceEpoch >= bufferDeadline(afterRebuilds: rebuildsWithoutAudio) ? .restart : .waiting
    }
}
