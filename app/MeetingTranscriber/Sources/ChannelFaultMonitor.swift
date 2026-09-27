import AudioTapLib
import Foundation

/// What is wrong with one capture channel, as opposed to what it happens to be
/// carrying.
/// The raw values are the `/state` wire names. They are the case names, so a
/// Swift rename would change the automation surface silently; `ChannelFaultMonitorTests`
/// pins them for that reason.
enum ChannelFault: String, Equatable {
    /// Nothing arrives from this channel any more, or ever did.
    ///
    /// Both halves of that are real and the second is the common one: the
    /// monitor falls back to the elapsed time when no buffer ever arrived, so a
    /// capture whose aggregate was created, started with `noErr` and never ran
    /// its IOProc lands here (issue #693) alongside one that delivered and then
    /// stopped. Causes, none of them established for a given report: the tap
    /// never started, the tap died, the device was unplugged, or the permission
    /// went away mid-recording. Anything copied from here into a user-facing
    /// message has to keep that open, which is what
    /// `ChannelFaultMessageTests` pins.
    case noBuffers

    /// Buffers keep arriving and every sample in them is zero. The transport is
    /// healthy; the device or the system muted the signal in front of it.
    case digitalSilence

    /// The capture was abandoned for good after a device change (issue #588).
    /// Terminal in a way the other two are not: the track is gone for the rest
    /// of the recording and only restarting the app brings it back.
    case gaveUp

    /// The opt-in silent-track watchdog rebuilt the app tap and the rebuilds
    /// did not bring non-zero samples back, so it stopped trying (issue #672).
    /// A silence report with one more fact in it: the automatic remedy has
    /// been tried. The channel is still capturing, which is what keeps this
    /// apart from `gaveUp`.
    case rebuildsExhausted

    /// The microphone went without a buffer for the capture layer's whole
    /// budget, across restarts and rebuilds of its engine, and was released
    /// (issues #724, #706). Unlike `gaveUp` nothing is stuck: a device change
    /// brings it back, which is what the message has to say.
    case stalled
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

    /// Its own latch for the same reason the give-up has one: it says
    /// something the silence report cannot, that rebuilding was tried and
    /// failed, so it is still worth reporting after one. It ends digital-
    /// silence reporting for the channel; buffers stopping later and a later
    /// give-up are still news.
    private var reportedRebuildsExhausted = false

    /// The stall count last reported, rather than a latch like the others:
    /// a stall says something the silence message cannot (restarting did not
    /// help, and what will), and a give-up after a revived capture wedges says
    /// something the stall could not (it is not coming back). Every further
    /// stall is news too, whether the revived microphone delivered in between
    /// or never did: either way the remedy did not hold.
    private var reportedStalls = 0

    /// Whether the last update saw the channel stalled, to find the revival.
    private var wasStalled = false

    /// When the current observation window began: the start of the recording,
    /// or the revival of a stalled channel. The ages the capture layer
    /// reports still span the stall when the flag clears, so a revived
    /// channel is judged only on what it did since, over a full window of its
    /// own, as a fresh recording would be.
    private var windowStart: TimeInterval = 0

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
    ///   - rebuildsExhausted: whether the silent-track watchdog stopped
    ///     rebuilding this channel's capture. Defaulted because only the app
    ///     channel has a watchdog, so false is the true answer everywhere else.
    ///   - stall: whether this channel's capture is released for lack of
    ///     audio, and how often it was. Defaulted because only the microphone
    ///     stalls.
    mutating func update(
        ages: ChannelSignalAges,
        gaveUp: Bool,
        elapsedSinceStart: TimeInterval,
        corroborated: Bool,
        rebuildsExhausted: Bool = false,
        stall: MicCaptureStall = MicCaptureStall(),
    ) -> ChannelFault? {
        // First, and without waiting for the window: this is already terminal
        // when the flag flips, and the window exists to rule out states that
        // recover on their own.
        if gaveUp, !reportedGiveUp {
            reportedGiveUp = true
            return .gaveUp
        }
        // Without the window, because the watchdog only gives up after
        // minutes of zeros and three rebuilds. With the same corroboration
        // `digitalSilence` needs (issue #614): the watchdog cannot tell a dead
        // tap from a far end that is silent, a muted call or a lobby, and this
        // pierces Focus, so it waits for the other channel to show the call is
        // live. The flag stays set, so a later corroborated tick reports it.
        if rebuildsExhausted, corroborated, !reportedRebuildsExhausted, !reportedGiveUp {
            reportedRebuildsExhausted = true
            return .rebuildsExhausted
        }
        // Also without a window: the capture layer already waited out its own
        // budget before it stalled.
        if stall.isActive {
            wasStalled = true
            if stall.count > reportedStalls {
                reportedStalls = stall.count
                if !reportedGiveUp { return .stalled }
            }
        } else if wasStalled {
            // Revived. Everything reported about the dead channel is re-armed,
            // silence included, so a revived microphone that is dead or
            // delivers only zeroes is reported like any other, once it has
            // had its window.
            wasStalled = false
            reportedSilence = false
            windowStart = elapsedSinceStart
        }
        // While stalled the stall message covers the silence.
        let observed = elapsedSinceStart - windowStart
        guard !reportedSilence, !reportedGiveUp, !stall.isActive, observed >= window else { return nil }

        let bufferAge = min(ages.secondsSinceLastBuffer ?? elapsedSinceStart, observed)
        if bufferAge >= window {
            reportedSilence = true
            return .noBuffers
        }

        // The watchdog report already said this channel is silent, with more
        // in it; a plain silence report after it would say less. A channel
        // that then stops delivering altogether is a different failure, which
        // is why only this arm is suppressed.
        let energyAge = min(ages.secondsSinceLastEnergy ?? elapsedSinceStart, observed)
        guard energyAge >= window, corroborated, !reportedRebuildsExhausted else { return nil }
        reportedSilence = true
        return .digitalSilence
    }

    mutating func reset() {
        reportedSilence = false
        reportedGiveUp = false
        reportedRebuildsExhausted = false
        reportedStalls = 0
        wasStalled = false
        windowStart = 0
    }
}
