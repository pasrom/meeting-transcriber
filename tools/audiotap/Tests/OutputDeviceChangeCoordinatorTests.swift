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
        XCTAssertEqual(action, .stopAndRetry(delay: CaptureRestartRetryPolicy.baseBackoff))
        XCTAssertEqual(coord.state, .retrying(attemptsSoFar: 1))
    }

    func testRestartingNegativeRateTriggersStopAndRetry() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        let action = coord.handle(.startSucceeded(rate: -1))
        XCTAssertEqual(action, .stopAndRetry(delay: CaptureRestartRetryPolicy.baseBackoff))
        XCTAssertEqual(coord.state, .retrying(attemptsSoFar: 1))
    }

    func testRestartingFailureTriggersRestart() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        let action = coord.handle(.startFailed)
        XCTAssertEqual(action, .restart(delay: CaptureRestartRetryPolicy.baseBackoff))
        XCTAssertEqual(coord.state, .retrying(attemptsSoFar: 1))
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
        // Spend the whole shared budget: giving up is what happens after the
        // last granted attempt, not after the first failure.
        var action = OutputDeviceChangeCoordinator.Action.ignore
        for _ in 0 ... CaptureRestartRetryPolicy.maxAttempts {
            action = coord.handle(.startFailed)
        }
        XCTAssertEqual(action, .giveUp)
        XCTAssertEqual(coord.state, .idle)
    }

    func testRetryPendingZeroRateGivesUp() {
        var coord = OutputDeviceChangeCoordinator()
        _ = coord.handle(.deviceChanged)
        var action = OutputDeviceChangeCoordinator.Action.ignore
        for _ in 0 ... CaptureRestartRetryPolicy.maxAttempts {
            action = coord.handle(.startSucceeded(rate: 0))
        }
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
        XCTAssertEqual(coord.state, .retrying(attemptsSoFar: 1))
    }

    // MARK: - Configuration & cycles

    func testCustomDelays() {
        var coord = OutputDeviceChangeCoordinator(
            initialRestartDelay: 0.1,
        ) { _ in .retry(afterSeconds: 0.2) }
        XCTAssertEqual(coord.handle(.deviceChanged), .stopAndRetry(delay: 0.1))
        XCTAssertEqual(coord.handle(.startFailed), .restart(delay: 0.2))
    }

    func testItSpendsTheSharedBudgetBeforeGivingUp() {
        // The regression this guards: the app channel used to get exactly two
        // attempts about a second apart, so an output device that took a few
        // seconds to re-enumerate lost its track terminally while the mic, on
        // the same event with the same policy, rode it out.
        var coord = OutputDeviceChangeCoordinator()
        XCTAssertEqual(coord.handle(.deviceChanged), .stopAndRetry(delay: 0.5))

        var actions: [OutputDeviceChangeCoordinator.Action] = []
        for _ in 0 ..< CaptureRestartRetryPolicy.maxAttempts + 1 {
            actions.append(coord.handle(.startFailed))
        }

        XCTAssertEqual(
            actions.count { if case .restart = $0 { true } else { false } },
            CaptureRestartRetryPolicy.maxAttempts,
            "every attempt the shared policy grants must actually be made",
        )
        XCTAssertEqual(actions.last, .giveUp)
        XCTAssertEqual(coord.state, .idle)
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
