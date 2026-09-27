@testable import AudioTapLib
import XCTest

/// What the capture session reports about the microphone's stall, as its
/// callbacks move it.
final class MicCaptureStallTests: XCTestCase {
    /// Every stall counts, a failed revival included, and a revival that
    /// delivered clears the stall without forgetting how many there were.
    func testEveryStallCountsAndAResumeKeepsTheCount() {
        var stall = MicCaptureStall()
        stall.noteStalled(MicStallDetails())
        stall.noteStalled(MicStallDetails())
        XCTAssertEqual(stall, MicCaptureStall(isActive: true, count: 2))
        stall.noteResumed()
        XCTAssertEqual(stall, MicCaptureStall(isActive: false, count: 2))
    }

    /// The latest stall's details are what the notice is worded from.
    func testTheLatestStallsDetailsAreKept() {
        var stall = MicCaptureStall()
        stall.noteStalled(MicStallDetails(everDelivered: false, mayRevive: true))
        stall.noteStalled(MicStallDetails(everDelivered: true, mayRevive: false))
        XCTAssertEqual(stall.details, MicStallDetails(everDelivered: true, mayRevive: false))
    }

    /// A revival that wedges gives up. The microphone is then lost for good,
    /// not released for lack of audio, so the stall ends with it rather than
    /// being reported alongside the give-up.
    func testAGiveUpEndsTheStall() {
        var stall = MicCaptureStall()
        stall.noteStalled(MicStallDetails())
        stall.noteGaveUp()
        XCTAssertEqual(stall, MicCaptureStall(isActive: false, count: 1))
    }
}
