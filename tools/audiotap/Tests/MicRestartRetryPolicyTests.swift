@testable import AudioTapLib
import XCTest

final class MicRestartRetryPolicyTests: XCTestCase {
    func testFirstFailureRetriesWithBaseBackoff() {
        XCTAssertEqual(
            MicRestartRetryPolicy.decide(attemptsSoFar: 0),
            .retry(afterSeconds: MicRestartRetryPolicy.baseBackoff),
        )
    }

    func testBackoffDoublesEachAttempt() {
        guard case let .retry(d0) = MicRestartRetryPolicy.decide(attemptsSoFar: 0),
              case let .retry(d1) = MicRestartRetryPolicy.decide(attemptsSoFar: 1),
              case let .retry(d2) = MicRestartRetryPolicy.decide(attemptsSoFar: 2)
        else {
            XCTFail("expected retries within budget")
            return
        }
        XCTAssertEqual(d1, d0 * 2, accuracy: 1e-9)
        XCTAssertEqual(d2, d0 * 4, accuracy: 1e-9)
    }

    func testBackoffIsCapped() {
        // A late (but still in-budget) attempt must not exceed the cap.
        guard case let .retry(delay) = MicRestartRetryPolicy.decide(attemptsSoFar: 4) else {
            XCTFail("expected a retry at attempt 4")
            return
        }
        XCTAssertLessThanOrEqual(delay, MicRestartRetryPolicy.maxBackoff)
    }

    func testGivesUpAtBudget() {
        XCTAssertEqual(
            MicRestartRetryPolicy.decide(attemptsSoFar: MicRestartRetryPolicy.maxAttempts),
            .giveUp,
        )
        XCTAssertEqual(
            MicRestartRetryPolicy.decide(attemptsSoFar: MicRestartRetryPolicy.maxAttempts + 3),
            .giveUp,
        )
    }

    func testLastInBudgetAttemptStillRetries() {
        guard case .retry = MicRestartRetryPolicy.decide(attemptsSoFar: MicRestartRetryPolicy.maxAttempts - 1) else {
            XCTFail("the final in-budget attempt should retry, not give up")
            return
        }
    }
}
