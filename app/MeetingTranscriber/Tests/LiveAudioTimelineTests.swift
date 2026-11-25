@testable import MeetingTranscriber
import XCTest

final class LiveAudioTimelineTests: XCTestCase {
    private let duration = 0.05

    func testLateAnchorIsCorrectedAfterOneSecondOfAudio() {
        var timeline = LiveAudioTimeline()
        // The first buffer was forwarded 50 ms late; every later one is on time.
        var placements = [timeline.place(stampedEnd: 10.05 + 0.05, duration: duration)]
        for index in 1 ... 25 {
            placements.append(timeline.place(stampedEnd: 10 + duration * Double(index + 1), duration: duration))
        }

        let realigned = placements.filter { $0.shift == .realigned }
        XCTAssertEqual(realigned.count, 1)
        XCTAssertEqual(realigned.first?.delta ?? 0, -0.05, accuracy: 1e-9)
        XCTAssertEqual(placements.last?.start ?? 0, 10 + duration * 25, accuracy: 1e-9, "placements must follow true time after the correction")
    }

    func testSlowClockDriftIsFollowedInsideTheBandAndNeverMovesForward() {
        var timeline = LiveAudioTimeline()
        // The mic clock runs slow: its stamps fall 5 ms per second further behind the sample count.
        var largestOffset = 0.0
        for index in 0 ..< 1200 {
            let trueEnd = 10 + duration * Double(index + 1)
            let stampedEnd = trueEnd * 1.005 - 10 * 0.005
            let placed = timeline.place(stampedEnd: stampedEnd, duration: duration)
            XCTAssertNotEqual(placed.shift, .forward, "a slow clock lost no audio")
            largestOffset = max(largestOffset, stampedEnd - duration - placed.start)
        }
        XCTAssertLessThan(largestOffset, 0.05, "drift must be corrected before it reaches the 0.1 s band")
    }

    func testThreeSecondsOfLateStampsDoNotMoveTimeline() {
        var timeline = LiveAudioTimeline()
        for index in 0 ..< 140 {
            // Buffer 0 anchors; buffers 41...100 are three full 1 s blocks, all forwarded 10 ms late.
            let late = (41 ... 100).contains(index) ? 0.01 : 0
            let placed = timeline.place(stampedEnd: 10 + duration * Double(index + 1) + late, duration: duration)
            XCTAssertEqual(placed.shift, .kept, "delivery delay only adds to a stamp; fewer than four late seconds is not drift")
        }
    }
}
