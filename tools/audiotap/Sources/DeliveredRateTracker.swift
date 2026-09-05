import Foundation

/// Measures the rate the tap is actually delivering, so a device that
/// renegotiates in place is followed (issue #673).
///
/// The capture rate used to be measured once, on the first IOProc callback, and
/// re-measured only after a restart, which only a default-output device change
/// triggers. A device that changes its nominal rate without the default device
/// changing keeps its UID, so no listener fires. `writeCapturedBuffer` then
/// hands the stale rate to the resampler, and because `TimelineAnchor` pads
/// against the hardware clock the damage takes two shapes: a drop leaves the
/// track its real length but alternating between real audio and exact zeros, a
/// rise leaves it about twice as long and an octave down, with nothing to
/// correct it because the anchor never removes frames.
///
/// This measures rather than asks. Two reasons, and the second decided it. A
/// *periodic* property read would have to go somewhere: on the write queue it is
/// the hazard of issue #588, a HAL call that never returns wedging the queue
/// whose `sync` drain every teardown waits on, and on a listener it needs a
/// lifetime across restart adoption, stale-attempt destroy and the give-up path,
/// where no HAL resource may be touched at all. (The one-shot read on the first
/// callback is a different bargain: it runs once per session, and this corrects
/// it if it was wrong.) More decisive, it is not established that our private
/// aggregate propagates a sub-device's in-place rate change, and issue #82
/// recorded a headset presenting 48 kHz nominal over a 24 kHz physical link with
/// the tap still delivering 48 kHz. Under that shape a listener on the nominal
/// rate would introduce the very defect it was meant to fix. Delivered frames
/// per second of the clock the anchor pads against is the quantity the resampler
/// needs, by definition, whichever way the HAL routed the change.
///
/// It is also the only rate source attached to the buffers being converted. The
/// creation-time ladder and the first-callback read both describe a device; an
/// IOProc block can outlive the attempt that resolved them.
///
/// The microphone channel needs no equivalent: `MicCaptureHandler` rebuilds its
/// converter from a fresh `hardwareFormat` on `AVAudioEngineConfigurationChange`
/// and hands the anchor post-conversion frames at a constant 16 kHz. The tap has
/// no such notification, and `actualSampleRate` outlives the `AppTapSession`
/// that resolved it.
///
/// Two small values of state, no allocation, no HAL call. Driven from the write
/// queue, one buffer at a time.
struct DeliveredRateTracker: Equatable {
    /// Non-overlapping measurement windows. 0.5 s is about 47 callbacks at
    /// 48 kHz with the 512-frame buffers every log in the repo shows.
    static let windowSeconds: Double = 0.5
    /// A window spanning longer than this is a restart gap or a corrupt stamp,
    /// not a measurement. Discarded rather than divided.
    static let maxWindowSeconds: Double = 2.0
    /// How far the largest gap between two buffers may exceed the window's
    /// average gap before the window is not a measurement of anything.
    ///
    /// This is what separates a device delivering fewer frames from a device
    /// delivering the same frames with some of them dropped, which the frame
    /// count alone cannot tell apart. A rate change moves every gap together,
    /// so the largest stays close to the average. A dropped callback leaves one
    /// gap at twice the period and the rest untouched. Without this, a stream
    /// losing a steady 8 to 9 % of its callbacks measures within 0.5 % of
    /// 44100 Hz coming from 48000, twice in a row, and gets adopted: the track
    /// then plays 8.8 % slow until two clean windows undo it.
    ///
    /// 1.5 rejects a window containing even one drop, which costs half a second
    /// of latency and buys the guarantee that only a uniform change is adopted.
    static let maxGapRatio: Double = 1.5

    private struct Window: Equatable {
        let start: Double
        /// The published rate this window is being measured against. When the
        /// caller publishes a different one (the restart adoption, the
        /// first-callback correction), the window is measuring against a rate
        /// that no longer applies and is thrown away.
        let publishedRate: Int
        var frames: Int
        /// The most recent buffer's stamp, and the shape of the gaps since the
        /// window opened. See `maxGapRatio` for what they are for.
        var lastStamp: Double
        var maxGap: Double = 0
        var gaps: Int = 0

        /// True when the buffers arrived evenly enough for their total to mean
        /// a rate. A window with no gap at all has nothing to say either way.
        var isRegular: Bool {
            guard gaps > 0 else { return false }
            let averageGap = (lastStamp - start) / Double(gaps)
            return maxGap <= averageGap * maxGapRatio
        }

        mutating func add(frames newFrames: Int, at stamp: Double) {
            maxGap = max(maxGap, stamp - lastStamp)
            gaps += 1
            lastStamp = stamp
            frames += newFrames
        }
    }

    private var window: Window?
    /// A rate that one closed window already proposed, waiting for a second.
    private var pendingCandidate: Int?

    /// Feed one buffer's frame count and presentation time. Returns a rate
    /// exactly once, when it has been confirmed and differs from `current`; the
    /// caller publishes it. Returns nil otherwise, which is almost always.
    ///
    /// `hostSeconds` is the presentation time of the buffer's *first* frame, so
    /// the frames of the buffer being observed lie after its stamp and belong to
    /// the window that stamp opens. That is the opposite convention from the app
    /// module's `SampleRateDriftDetector`, whose stamps are taken after capture
    /// and which therefore drops its first entry instead of its last.
    mutating func observe(frames: Int, hostSeconds: Double, current: Int) -> Int? {
        guard frames > 0, hostSeconds.isFinite else { return nil }
        guard var open = window, open.publishedRate == current else {
            restart(at: hostSeconds, rate: current, frames: frames)
            return nil
        }
        let span = hostSeconds - open.start
        guard span >= 0, span <= Self.maxWindowSeconds else {
            // The clock went backwards, or a restart left a hole. Either way the
            // frames counted so far say nothing about a rate.
            restart(at: hostSeconds, rate: current, frames: frames)
            return nil
        }
        guard span >= Self.windowSeconds else {
            open.add(frames: frames, at: hostSeconds)
            window = open
            return nil
        }
        open.add(frames: frames, at: hostSeconds)

        // The closing buffer's own frames belong to the next window, so the
        // count divided here is everything that arrived before its stamp.
        let measured = Double(open.frames - frames) / span
        let confirmed = confirm(
            open.isRegular
                ? SampleRateQuery.confirmedRateChange(measured: measured, current: current)
                : nil,
        )
        // Opened against what the caller is about to publish, so the next buffer
        // does not throw away a window that is already correct.
        window = Window(
            start: hostSeconds, publishedRate: confirmed ?? current,
            frames: frames, lastStamp: hostSeconds,
        )
        return confirmed
    }

    /// A candidate becomes the answer only on a second consecutive window that
    /// proposes the same one, and any window that proposes nothing clears it.
    ///
    /// One window is not enough because the window that straddles the switch
    /// measures something between the old rate and the new one, and one of those
    /// in-between values can land close enough to an unrelated standard rate to
    /// pass every test in `confirmedRateChange`: 48 to 24 kHz at 84 % of a window
    /// reads as 44160 Hz, which is within 0.14 % of 44100.
    private mutating func confirm(_ candidate: Int?) -> Int? {
        guard let candidate else {
            pendingCandidate = nil
            return nil
        }
        guard candidate == pendingCandidate else {
            pendingCandidate = candidate
            return nil
        }
        pendingCandidate = nil
        return candidate
    }

    private mutating func restart(at seconds: Double, rate: Int, frames: Int) {
        window = Window(start: seconds, publishedRate: rate, frames: frames, lastStamp: seconds)
        pendingCandidate = nil
    }
}
