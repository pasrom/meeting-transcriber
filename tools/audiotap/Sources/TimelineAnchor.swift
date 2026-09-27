import Foundation

/// Tracks an audio track's position on a wall-clock timeline anchored to its
/// first captured buffer, or to the capture's start for a track restarted
/// before it had one, so a device-change restart gap becomes silence and the
/// track stays aligned to real time (issue #379 follow-up).
///
/// The capture handler feeds each buffer's *hardware* host-time (jitter-free
/// presentation time, e.g. `AVAudioTime.hostTime` or `AudioTimeStamp.mHostTime`,
/// converted to seconds) and its frame count; the anchor returns how many silent
/// frames to write before that buffer. Using the hardware timestamp — not the
/// callback wall-clock — means continuous capture inserts nothing (the timestamp
/// advances exactly with the audio), while a restart gap, where the timestamp
/// jumps forward, is filled precisely.
///
/// Survives restarts: it is anchored once and never reset, so
/// the gap between the last pre-restart buffer and the first post-restart buffer
/// is bridged automatically. Not thread-safe. `silenceFramesBefore` runs in the
/// capture callback. The calls from elsewhere, `anchorBeforeFirstBuffer` and
/// `bridgeNextGap` on the main queue and the pending bridge on the restart
/// queue, are made while a restart attempt is out, when no callback
/// can reach the anchor: the outgoing engine was torn down and the new one's
/// tap drops every buffer until the restart arbiter flips the phase to
/// capturing, which happens after those calls and under the lock the callback
/// reads the phase through, so the callback sees what they wrote. One window
/// stays open: tearing the outgoing engine down does not wait for a callback
/// that already passed its phase check, so that one buffer can still reach
/// the anchor while a restart is starting, as it always could for the gap
/// fill.
struct TimelineAnchor {
    let rate: Int
    private var anchorHostSeconds: Double?
    private var framesWritten = 0
    private var bridgingNextGap = false

    /// Gaps beyond this are treated as a corrupt timestamp, not a real device
    /// outage: no silence is inserted (the write would be gigabytes of zeros on
    /// the audio thread, and `AVAudioFrameCount` traps past UInt32.max). The
    /// anchor is absolute, so a one-off glitched buffer self-heals on the next
    /// sane timestamp.
    static let maxGapSeconds: Double = 600

    /// Let the next gap through uncapped, for a gap the caller knows is real:
    /// a microphone revived after it stalled for lack of audio, which can last
    /// any length of time. The anomaly cap exists to reject a corrupt
    /// timestamp, and applied to a real stall it would leave every later
    /// sample early by the whole stall. Bridged at the next buffer's own
    /// presentation time rather than when the revival was adopted, so the
    /// revived audio is not late by that buffer's capture latency, and never
    /// past the wall-clock time the buffer arrives at, so a corrupt timestamp
    /// on that buffer cannot write more silence than time actually passed.
    mutating func bridgeNextGap() {
        bridgingNextGap = true
    }

    /// Anchor a track that has no buffer yet at `hostSeconds`, the moment its
    /// capture started, and bridge the wait for its first buffer. For a
    /// capture restarted before it ever delivered: anchored at that first
    /// buffer instead, the track would begin however late the buffer came,
    /// and a microphone delay past the mixer's 30 s clamp puts it early in
    /// the mix by the rest. Returns whether it anchored, which it does only
    /// before the first buffer.
    mutating func anchorBeforeFirstBuffer(atHostSeconds hostSeconds: Double) -> Bool {
        guard anchorHostSeconds == nil else { return false }
        anchorHostSeconds = hostSeconds
        framesWritten = 0
        bridgingNextGap = true
        return true
    }

    /// The silence a pending bridge owes up to `hostSeconds`, so the bulk of
    /// a long stall can be written before the next buffer rather than inside
    /// its callback. Zero with nothing pending. Not counted as written until
    /// `noteBridgeWritten` says how much reached the file: a write can stop
    /// or fail partway, and counting what never landed would put the rest of
    /// the track early by the shortfall.
    func pendingBridge(toHostSeconds hostSeconds: Double) -> Int {
        guard bridgingNextGap, let anchor = anchorHostSeconds else { return 0 }
        return max(0, Int(((hostSeconds - anchor) * Double(rate)).rounded()) - framesWritten)
    }

    /// Count `frames` of a pending bridge as written. The bridge stays
    /// pending for whatever is still owed, up to the next buffer's own time.
    mutating func noteBridgeWritten(frames: Int) {
        framesWritten += frames
    }

    init(rate: Int) {
        self.rate = rate
    }

    /// Silent frames to insert before a buffer that presents at `hostSeconds`
    /// carrying `frameCount` frames, to keep the written stream aligned to
    /// wall-clock. The first call sets the anchor and inserts nothing. Never
    /// negative — an early/jittered timestamp just appends.
    mutating func silenceFramesBefore(
        hostSeconds: Double,
        frameCount: Int,
        arrivedAt nowSeconds: Double = .infinity,
    ) -> Int {
        guard let anchor = anchorHostSeconds else {
            anchorHostSeconds = hostSeconds
            framesWritten = frameCount
            bridgingNextGap = false
            return 0
        }
        if bridgingNextGap {
            bridgingNextGap = false
            let expected = Int(((min(hostSeconds, nowSeconds) - anchor) * Double(rate)).rounded())
            let silence = max(0, expected - framesWritten)
            framesWritten += silence + frameCount
            return silence
        }
        let expected = Int(((hostSeconds - anchor) * Double(rate)).rounded())
        let silence = max(0, expected - framesWritten)
        guard silence <= Int(Self.maxGapSeconds * Double(rate)) else {
            framesWritten += frameCount
            return 0
        }
        framesWritten += silence + frameCount
        return silence
    }
}
