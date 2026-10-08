@testable import AudioTapLib
import XCTest

final class TimelineAnchorTests: XCTestCase {
    func testFirstBufferAnchorsWithoutSilence() {
        var anchor = TimelineAnchor(rate: 16000)
        // The first buffer defines t=0 for the track — nothing precedes it.
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 100.0, frameCount: 1600), 0)
    }

    func testContinuousCaptureInsertsNoSilence() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100.0, frameCount: 1600) // anchor, 0.1 s written
        // Next buffer exactly 0.1 s later carrying 0.1 s of audio → perfectly on time.
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 100.1, frameCount: 1600), 0)
    }

    /// The core of the fix. A device-change restart drops audio for the
    /// teardown→rebuild gap; the next buffer's hardware timestamp jumps forward
    /// by the real gap. That jump must become silence so the track stays aligned
    /// to wall-clock instead of under-running (jhavez's −18.5 s mic drift).
    func testRestartGapInsertsSilence() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100.0, frameCount: 1600) // written 1600
        _ = anchor.silenceFramesBefore(hostSeconds: 100.1, frameCount: 1600) // written 3200
        // 2.6 s restart gap: buffer arrives at t=102.7. expected = 2.7 × 16000 =
        // 43200, written 3200 → insert 40000 silent frames before it.
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 102.7, frameCount: 1600), 40000)
    }

    /// A corrupt timestamp far in the future must not produce a giant silence
    /// block (gigabytes of zeros on the audio thread; `AVAudioFrameCount` traps
    /// past UInt32.max). Treated as an anomaly: nothing inserted, and the next
    /// sane buffer self-heals against the absolute anchor.
    func testAnomalousTimestampJumpIsNotFilled() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100.0, frameCount: 1600)
        XCTAssertEqual(
            anchor.silenceFramesBefore(hostSeconds: 100.0 + 7200, frameCount: 1600), 0,
            "a 2 h timestamp jump is a corrupt clock, not a real gap",
        )
        XCTAssertEqual(
            anchor.silenceFramesBefore(hostSeconds: 100.2, frameCount: 1600), 0,
            "the next sane buffer must resume normally",
        )
    }

    /// A timestamp slightly behind the write head (clock jitter / converter
    /// latency wobble) must never produce negative silence — we pad, never drop.
    func testEarlyBufferNeverNegative() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100.0, frameCount: 16000) // 1 s written
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 100.5, frameCount: 1600), 0)
    }

    // MARK: - Bridging a stall

    /// A capture released for lack of audio can be revived after any length of
    /// time. That gap is real, not an anomalous timestamp, so the first buffer
    /// after the revival bridges it in full at its own presentation time, and
    /// the buffer after it lines up again.
    func testABridgedGapIsFilledPastTheAnomalyCap() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100, frameCount: 160)
        let gap = TimelineAnchor.maxGapSeconds * 2
        anchor.bridgeNextGap()
        XCTAssertEqual(
            anchor.silenceFramesBefore(hostSeconds: 100 + gap, frameCount: 160, arrivedAt: 100 + gap + 0.05),
            Int(gap * 16000) - 160,
        )
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 100 + gap + 0.01, frameCount: 160), 0, "aligned again")
    }

    /// Only one gap is let through: the cap applies again afterwards.
    func testTheBridgeLetsOneGapThrough() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100, frameCount: 160)
        anchor.bridgeNextGap()
        _ = anchor.silenceFramesBefore(hostSeconds: 101, frameCount: 160)
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 101 + TimelineAnchor.maxGapSeconds * 2, frameCount: 160), 0)
    }

    /// A capture that stalled before its first buffer has nothing to bridge:
    /// the revived first buffer anchors the track, and the recorder's
    /// first-frame time carries the offset. The bridge is spent on it, so a
    /// corrupt gap on the buffer after is still capped.
    func testABridgeBeforeTheFirstBufferIsSpentOnTheAnchor() {
        var anchor = TimelineAnchor(rate: 16000)
        anchor.bridgeNextGap()
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 5000, frameCount: 160), 0)
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 5000 + TimelineAnchor.maxGapSeconds * 2, frameCount: 160), 0)
    }

    /// A track restarted before its first buffer is anchored at the capture's
    /// start, and that first buffer bridges the wait uncapped.
    func testAnAnchorBeforeTheFirstBufferBridgesTheWait() {
        var anchor = TimelineAnchor(rate: 16000)
        XCTAssertTrue(anchor.anchorBeforeFirstBuffer(atHostSeconds: 100))
        let wait = TimelineAnchor.maxGapSeconds * 2
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 100 + wait, frameCount: 160), Int(wait * 16000))
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 100 + wait + 0.01, frameCount: 160), 0, "aligned")
    }

    /// Once a buffer anchored the track, the capture start no longer moves it.
    func testAnAnchorBeforeTheFirstBufferIsIgnoredAfterIt() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100, frameCount: 160)
        XCTAssertFalse(anchor.anchorBeforeFirstBuffer(atHostSeconds: 50))
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 100.01, frameCount: 160), 0)
    }

    /// The bulk of a pending bridge is taken up front, and the next buffer
    /// fills only what is left up to its own time.
    func testABridgeTakenUpFrontLeavesTheBufferOnlyTheRest() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100, frameCount: 160)
        XCTAssertEqual(anchor.pendingBridge(toHostSeconds: 1000), 0, "nothing pending")
        anchor.bridgeNextGap()
        let pending = anchor.pendingBridge(toHostSeconds: 1000)
        XCTAssertEqual(pending, 900 * 16000 - 160)
        anchor.noteBridgeWritten(frames: pending)
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 1002, frameCount: 160), 2 * 16000)
    }

    /// A bridge write that failed partway counts only what reached the file,
    /// and the next buffer fills the rest: counted in full, the rest of the
    /// track would sit early by the shortfall.
    func testABridgeWrittenOnlyInPartLeavesTheRestToTheNextBuffer() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100, frameCount: 160)
        anchor.bridgeNextGap()
        _ = anchor.pendingBridge(toHostSeconds: 1000)
        anchor.noteBridgeWritten(frames: 100 * 16000)
        XCTAssertEqual(anchor.silenceFramesBefore(hostSeconds: 1002, frameCount: 160), 802 * 16000 - 160)
    }

    /// A corrupt timestamp on the bridging buffer cannot write more silence
    /// than wall-clock time has passed by the time the buffer arrives.
    func testTheBridgeIsBoundedByTheArrivalTime() {
        var anchor = TimelineAnchor(rate: 16000)
        _ = anchor.silenceFramesBefore(hostSeconds: 100, frameCount: 160)
        anchor.bridgeNextGap()
        XCTAssertEqual(
            anchor.silenceFramesBefore(hostSeconds: 100 + 86400 * 3, frameCount: 160, arrivedAt: 100 + 1300),
            1300 * 16000 - 160,
        )
    }
}
