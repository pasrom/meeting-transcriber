@testable import AudioTapLib
import XCTest

final class LevelPublisherTests: XCTestCase {
    func testInitialLevelIsFloor() {
        let publisher = LevelPublisher()
        XCTAssertEqual(publisher.currentLevelDBFS, -120, accuracy: 0.001)
    }

    func testPublishedLevelIsReadback() {
        let publisher = LevelPublisher()
        publisher.publish(level: -24, hasEnergy: true)
        XCTAssertEqual(publisher.currentLevelDBFS, -24, accuracy: 0.001)
    }

    func testReadingDecaysToFloorAfterStaleness() {
        // 10 ms staleness threshold lets us assert decay without long sleeps.
        let publisher = LevelPublisher(stalenessSec: 0.01)
        publisher.publish(level: -12, hasEnergy: true)
        // Wait past the threshold.
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(publisher.currentLevelDBFS, -120, accuracy: 0.001)
    }

    // MARK: - Signal ages

    func testAgesAreUnknownBeforeTheFirstBuffer() {
        let publisher = LevelPublisher()
        XCTAssertNil(publisher.currentSignalAges.secondsSinceLastBuffer)
        XCTAssertNil(publisher.currentSignalAges.secondsSinceLastEnergy)
    }

    func testPublishingWithEnergyStartsBothAges() throws {
        let publisher = LevelPublisher()
        publisher.publish(level: -24, hasEnergy: true)
        let ages = publisher.currentSignalAges
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastBuffer), 0, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastEnergy), 0, accuracy: 0.5)
    }

    func testPublishingWithoutEnergyStartsOnlyTheBufferAge() throws {
        // A muted device still delivers buffers; that is the whole point of
        // keeping the two ages apart.
        let publisher = LevelPublisher()
        publisher.publish(level: -120, hasEnergy: false)
        let ages = publisher.currentSignalAges
        XCTAssertEqual(try XCTUnwrap(ages.secondsSinceLastBuffer), 0, accuracy: 0.5)
        XCTAssertNil(ages.secondsSinceLastEnergy)
    }

    func testASilentBufferDoesNotRefreshTheEnergyAge() throws {
        let publisher = LevelPublisher()
        publisher.publish(level: -24, hasEnergy: true)
        Thread.sleep(forTimeInterval: 0.05)
        publisher.publish(level: -120, hasEnergy: false)
        let ages = publisher.currentSignalAges
        XCTAssertLessThan(try XCTUnwrap(ages.secondsSinceLastBuffer), 0.02)
        XCTAssertGreaterThan(try XCTUnwrap(ages.secondsSinceLastEnergy), 0.04)
    }

    func testFreshPublishReplacesStaleReading() {
        let publisher = LevelPublisher(stalenessSec: 0.01)
        publisher.publish(level: -12, hasEnergy: true)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(publisher.currentLevelDBFS, -120, accuracy: 0.001)
        publisher.publish(level: -8, hasEnergy: true)
        XCTAssertEqual(publisher.currentLevelDBFS, -8, accuracy: 0.001)
    }
}
