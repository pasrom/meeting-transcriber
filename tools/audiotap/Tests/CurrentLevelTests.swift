@testable import AudioTapLib
import XCTest

final class CurrentLevelTests: XCTestCase {
    func testNeverUpdatedReturnsFloor() {
        let result = currentLevel(level: -12, lastUpdateTicks: 0, nowTicks: 1_000_000_000, stalenessSec: 0.5)
        XCTAssertEqual(result, -120, accuracy: 0.001)
    }

    func testFreshReadingReturnsLevel() {
        let now = secondsToMachTicks(10)
        let last = secondsToMachTicks(9.9) // 100 ms old
        XCTAssertEqual(currentLevel(level: -24, lastUpdateTicks: last, nowTicks: now, stalenessSec: 0.5), -24, accuracy: 0.001)
    }

    func testStaleReadingReturnsFloor() {
        let now = secondsToMachTicks(10)
        let last = secondsToMachTicks(9) // 1 s old, > 0.5 s threshold
        XCTAssertEqual(currentLevel(level: -24, lastUpdateTicks: last, nowTicks: now, stalenessSec: 0.5), -120, accuracy: 0.001)
    }

    func testAtThresholdReturnsLevel() {
        // Boundary: age == staleness is NOT stale (strict >).
        let now = secondsToMachTicks(10)
        let last = secondsToMachTicks(9.5) // exactly 0.5 s old
        XCTAssertEqual(currentLevel(level: -24, lastUpdateTicks: last, nowTicks: now, stalenessSec: 0.5), -24, accuracy: 0.001)
    }
}
