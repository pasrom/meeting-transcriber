@testable import AudioTapLib
import XCTest

final class HelpersTests: XCTestCase {
    func testMachTicksToSecondsZero() {
        XCTAssertEqual(machTicksToSeconds(0), 0.0)
    }

    func testMachTicksToSecondsPositive() {
        let ticks: UInt64 = 1_000_000_000
        let seconds = machTicksToSeconds(ticks)
        XCTAssertGreaterThan(seconds, 0)
        // On Apple Silicon mach ticks == nanoseconds, so ~1.0s
        // On Intel ratio differs. Just check plausible range.
        XCTAssertGreaterThan(seconds, 0.01)
        XCTAssertLessThan(seconds, 100)
    }

    func testMachTicksToSecondsMonotonic() {
        let s1 = machTicksToSeconds(1000)
        let s2 = machTicksToSeconds(2000)
        XCTAssertGreaterThan(s2, s1)
    }

    func testSpeechSampleRateConstant() {
        XCTAssertEqual(speechSampleRate, 16000)
    }
}
