import AudioTapLib
import Foundation

/// What is wrong with one capture channel, as opposed to what it happens to be
/// carrying.
/// The raw values are the `/state` wire names. They are the case names, so a
/// Swift rename would change the automation surface silently; `ChannelFaultMonitorTests`
/// pins them for that reason.
enum ChannelFault: String, Equatable {
    /// Nothing arrives from this channel any more, or ever did. The tap died,
    /// the device was unplugged, or the permission went away mid-recording.
    case noBuffers

    /// Buffers keep arriving and every sample in them is zero. The transport is
    /// healthy; the device or the system muted the signal in front of it.
    case digitalSilence

    /// The capture was abandoned for good after a device change (issue #588).
    /// Terminal in a way the other two are not: the track is gone for the rest
    /// of the recording and only restarting the app brings it back.
    case gaveUp
}

/// Decides whether one capture channel has failed, from what the capture layer
/// reports per buffer rather than from a polled level.
///
/// Kept apart from `ChannelHealthMonitor` on purpose. That one answers "is this
/// channel unusually quiet compared to the other", which is the right question
/// for the menu-bar tint and the wrong one for a notification: a microphone
/// whose owner is listening rather than talking is quiet, and telling them so
/// every ninety seconds is what issue #614 is about. This one answers "is this
/// channel still delivering", which a level cannot express, and which is the
/// same question in a browser meeting as in a native one because it never looks
/// at the meeting app.
///
/// Two properties matter for how it is fed:
///
/// - It reads ages, not tick counts. The published level stays fresh for 500 ms
///   while the controller polls every 100 ms, so a single buffer would be
///   counted about five times; anything counted up there measures the poll
///   cadence, not the channel.
/// - It is evaluated on every tick, not when some other state machine reaches
///   an edge. `ChannelHealthMonitor` latches its episode and only clears it
///   when the silent side climbs back over the speech threshold, which a dead
///   channel never does, so a decision taken at that edge is taken exactly once
///   and can never be revisited.
struct ChannelFaultMonitor {
    /// How long a channel must be in the failed state before it is reported.
    /// Shares the user-facing "Warn after" setting with the tint, so there is
    /// one number to reason about rather than two.
    let window: TimeInterval

    /// A channel fails once per recording as far as the user is concerned. The
    /// failure modes escalate into each other (a device that stops delivering
    /// was usually delivering zeroes first), and reporting each step is the
    /// repetition this whole change exists to remove.
    private var reportedSilence = false

    /// Tracked apart from the silence report because the two are not the same
    /// news. A give-up says the channel is not coming back without a restart,
    /// which the silence message cannot say, so it is still worth reporting
    /// after one; the reverse is not, so a give-up ends silence reporting for
    /// this channel. Keeping both here is the point: as two latches in two
    /// functions the precedence was written down nowhere, and the order the
    /// two failures happened to arrive in decided whether the user heard about
    /// the channel twice or the state showed no fault at all.
    private var reportedGiveUp = false

    init(window: TimeInterval) {
        self.window = window
    }

    /// - Parameters:
    ///   - ages: what the capture layer knows about this channel. `nil` ages
    ///     mean "never", and are measured against the age of the recording.
    ///   - elapsedSinceStart: how long this recording has been running, so a
    ///     channel that never delivered is judged only once the window has had
    ///     a chance to pass.
    ///   - corroborated: whether the recording is known to be capturing
    ///     anything at all right now, i.e. whether the *other* channel carried
    ///     speech inside the window. Gates `digitalSilence` only: zeroes are
    ///     also what a healthy channel carries when its source is silent, and
    ///     a recording where nothing at all is happening belongs to
    ///     `SilentRecordingMonitor`.
    ///   - gaveUp: whether this channel's capture was abandoned for good. Not
    ///     derivable from the ages: a channel that gave up may have delivered a
    ///     buffer a moment ago, and no age can say it will never deliver
    ///     another.
    mutating func update(
        ages: ChannelSignalAges,
        gaveUp: Bool,
        elapsedSinceStart: TimeInterval,
        corroborated: Bool,
    ) -> ChannelFault? {
        // First, and without waiting for the window: this is already terminal
        // when the flag flips, and the window exists to rule out states that
        // recover on their own.
        if gaveUp, !reportedGiveUp {
            reportedGiveUp = true
            return .gaveUp
        }
        guard !reportedSilence, !reportedGiveUp, elapsedSinceStart >= window else { return nil }

        let bufferAge = ages.secondsSinceLastBuffer ?? elapsedSinceStart
        if bufferAge >= window {
            reportedSilence = true
            return .noBuffers
        }

        let energyAge = ages.secondsSinceLastEnergy ?? elapsedSinceStart
        guard energyAge >= window, corroborated else { return nil }
        reportedSilence = true
        return .digitalSilence
    }

    mutating func reset() {
        reportedSilence = false
        reportedGiveUp = false
    }
}
