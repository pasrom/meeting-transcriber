@testable import AudioTapLib
import XCTest

final class OutputDeviceChangeCoordinatorTests: XCTestCase {
    // MARK: - Idle

    func testIdleDeviceChangeBeginsRestart() {
        var coord = OutputDeviceChangeCoordinator()
        let action = coord.handle(.deviceChanged)
        XCTAssertEqual(action, .stopAndRetry(delay: 0.5))
        XCTAssertEqual(coord.state, .restarting)
    }

    func testStartEventsInIdleAreIgnored() {
        var coord = OutputDeviceChangeCoordinator()
        XCTAssertEqual(coord.handle(.startSucceeded(rate: 48000)), .ignore)
        XCTAssertEqual(coord.handle(.startFailed), .ignore)
        XCTAssertEqual(coord.state, .idle)
    }

    // MARK: - Restarting

    func testRestartingSuccessReturnsToIdle() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        let action = coord.handle(.startSucceeded(rate: 48000))
        XCTAssertEqual(action, .complete)
        XCTAssertEqual(coord.state, .idle)
    }

    func testRestartingZeroRateTriggersStopAndRetry() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        let action = coord.handle(.startSucceeded(rate: 0))
        XCTAssertEqual(action, .stopAndRetry(delay: 1.0))
        XCTAssertEqual(coord.state, .retryPending)
    }

    func testRestartingNegativeRateTriggersStopAndRetry() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        let action = coord.handle(.startSucceeded(rate: -1))
        XCTAssertEqual(action, .stopAndRetry(delay: 1.0))
        XCTAssertEqual(coord.state, .retryPending)
    }

    func testRestartingFailureTriggersRestart() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        let action = coord.handle(.startFailed)
        XCTAssertEqual(action, .restart(delay: 1.0))
        XCTAssertEqual(coord.state, .retryPending)
    }

    // MARK: - Retry pending

    func testRetryPendingSuccessCompletes() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        _ = coord.handle(.startFailed)
        let action = coord.handle(.startSucceeded(rate: 44100))
        XCTAssertEqual(action, .complete)
        XCTAssertEqual(coord.state, .idle)
    }

    func testRetryPendingFailureGivesUp() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        _ = coord.handle(.startFailed)
        let action = coord.handle(.startFailed)
        XCTAssertEqual(action, .giveUp)
        XCTAssertEqual(coord.state, .idle)
    }

    func testRetryPendingZeroRateGivesUp() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        _ = coord.handle(.startFailed)
        let action = coord.handle(.startSucceeded(rate: 0))
        XCTAssertEqual(action, .giveUp)
        XCTAssertEqual(coord.state, .idle)
    }

    // MARK: - Re-entrancy

    func testReentrantDeviceChangeWhileRestartingIsIgnored() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        let action = coord.handle(.deviceChanged)
        XCTAssertEqual(action, .ignore)
        XCTAssertEqual(coord.state, .restarting)
    }

    func testReentrantDeviceChangeWhileRetryingIsIgnored() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        _ = coord.handle(.startFailed)
        let action = coord.handle(.deviceChanged)
        XCTAssertEqual(action, .ignore)
        XCTAssertEqual(coord.state, .retryPending)
    }

    // MARK: - Configuration & cycles

    func testCustomDelays() {
        var coord = OutputDeviceChangeCoordinator(initialRestartDelay: 0.1, retryDelay: 0.2)
        XCTAssertEqual(coord.handle(.deviceChanged), .stopAndRetry(delay: 0.1))
        XCTAssertEqual(coord.handle(.startFailed), .restart(delay: 0.2))
    }

    func testNewCycleAcceptedAfterCompletion() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        _ = coord.handle(.startSucceeded(rate: 48000))
        XCTAssertEqual(coord.state, .idle, "completion must return to idle")
        let secondCycle = coord.handle(.deviceChanged)
        XCTAssertEqual(secondCycle, .stopAndRetry(delay: 0.5))
        XCTAssertEqual(coord.state, .restarting)
    }
}
