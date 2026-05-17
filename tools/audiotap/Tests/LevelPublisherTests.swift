@testable import AudioTapLib
import XCTest

final class LevelPublisherTests: XCTestCase {
    func testInitialLevelIsFloor() {
        let publisher = LevelPublisher()
        XCTAssertEqual(publisher.currentLevelDBFS, -120, accuracy: 0.001)
    }

    func testPublishedLevelIsReadback() {
        let publisher = LevelPublisher()
        publisher.publish(level: -24)
        XCTAssertEqual(publisher.currentLevelDBFS, -24, accuracy: 0.001)
    }

    func testReadingDecaysToFloorAfterStaleness() {
        // 10 ms staleness threshold lets us assert decay without long sleeps.
        let publisher = LevelPublisher(stalenessSec: 0.01)
        publisher.publish(level: -12)
        // Wait past the threshold.
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(publisher.currentLevelDBFS, -120, accuracy: 0.001)
    }

    func testFreshPublishReplacesStaleReading() {
        let publisher = LevelPublisher(stalenessSec: 0.01)
        publisher.publish(level: -12)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(publisher.currentLevelDBFS, -120, accuracy: 0.001)
        publisher.publish(level: -8)
        XCTAssertEqual(publisher.currentLevelDBFS, -8, accuracy: 0.001)
    }
}
