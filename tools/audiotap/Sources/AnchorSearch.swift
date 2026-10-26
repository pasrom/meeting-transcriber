import Foundation

/// Where the anchor search currently sits: which candidate the tap is anchored
/// to, and which anchor last proved it delivers audio.
///
/// Split from `OutputDeviceAnchorPolicy` because that type answers "what are
/// the options, in what order" from device facts alone, while this one carries
/// the state that accumulates *across* attempts within one recording. Keeping
/// them apart is what lets the cursor rules — advance on a proven-dead anchor,
/// reset on a device change, stop at the end of the list — be tested without
/// any notion of a CoreAudio device.
struct AnchorSearch: Equatable {
    /// Index into the candidate list from `OutputDeviceAnchorPolicy`. Zero is
    /// the current system default, which is where every search starts and
    /// returns to.
    private(set) var cursor = 0

    /// The most recent anchor at which the tap actually delivered nonzero
    /// samples, or nil before anything has ever arrived.
    ///
    /// The whole point of the redesign is that this is *earned*, not inferred:
    /// a device qualifies by having carried audio, not by having a transport we
    /// approve of. It is what makes the search self-correcting — after a
    /// working stretch, the fallback is a device known to work rather than a
    /// guess.
    private(set) var lastKnownGoodUID: String?

    /// Advance past an anchor that has been proven to deliver nothing.
    ///
    /// - Returns: true when there is another candidate to try. False means the
    ///   list is exhausted; the caller latches and stops rather than cycling,
    ///   because re-trying a set of anchors that have each already failed only
    ///   costs more audio.
    mutating func advance(candidateCount: Int) -> Bool {
        guard cursor + 1 < candidateCount else { return false }
        cursor += 1
        return true
    }

    /// A genuine default-output change is a new situation, so the search starts
    /// over at position 0.
    ///
    /// Load-bearing for the case this whole mechanism exists for: when the
    /// meeting app hands the default *back* to real hardware, the tap must
    /// follow it there immediately rather than stay parked on the fallback it
    /// escaped to. Without the reset, one bad stretch would strand the anchor
    /// for the rest of the recording.
    mutating func resetToDefault() {
        cursor = 0
    }

    /// Record that audio genuinely arrived at `uid`.
    ///
    /// Idempotent per anchor: the caller invokes this from the buffer path, so
    /// it must stay cheap and must not churn on every buffer of a healthy
    /// recording.
    mutating func recordDelivery(at uid: String) {
        guard lastKnownGoodUID != uid else { return }
        lastKnownGoodUID = uid
    }

    /// Which candidate to anchor to now.
    ///
    /// Clamps rather than trapping: the candidate list is rebuilt on every
    /// attempt from a live device enumeration, so it can legitimately shrink
    /// under a cursor that was valid a moment ago — a user unplugging an
    /// interface mid-search does exactly that.
    func selection(from candidates: [OutputDeviceAnchorPolicy.Candidate])
        -> (candidate: OutputDeviceAnchorPolicy.Candidate, position: Int)? {
        guard !candidates.isEmpty else { return nil }
        let index = min(cursor, candidates.count - 1)
        return (candidates[index], index)
    }
}
