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
}
