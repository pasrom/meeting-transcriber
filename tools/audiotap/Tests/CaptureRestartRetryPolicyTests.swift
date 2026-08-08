@testable import AudioTapLib
import XCTest

final class CaptureRestartRetryPolicyTests: XCTestCase {
    func testFirstFailureRetriesWithBaseBackoff() {
        XCTAssertEqual(
            CaptureRestartRetryPolicy.decide(attemptsSoFar: 0),
            .retry(afterSeconds: CaptureRestartRetryPolicy.baseBackoff),
        )
    }

    func testBackoffDoublesEachAttempt() {
        guard case let .retry(d0) = CaptureRestartRetryPolicy.decide(attemptsSoFar: 0),
              case let .retry(d1) = CaptureRestartRetryPolicy.decide(attemptsSoFar: 1),
              case let .retry(d2) = CaptureRestartRetryPolicy.decide(attemptsSoFar: 2)
        else {
            XCTFail("expected retries within budget")
            return
        }
        XCTAssertEqual(d1, d0 * 2, accuracy: 1e-9)
        XCTAssertEqual(d2, d0 * 4, accuracy: 1e-9)
    }

    func testBackoffIsCapped() {
        // A late (but still in-budget) attempt must not exceed the cap.
        guard case let .retry(delay) = CaptureRestartRetryPolicy.decide(attemptsSoFar: 4) else {
            XCTFail("expected a retry at attempt 4")
            return
        }
        XCTAssertLessThanOrEqual(delay, CaptureRestartRetryPolicy.maxBackoff)
    }

    func testGivesUpAtBudget() {
        XCTAssertEqual(
            CaptureRestartRetryPolicy.decide(attemptsSoFar: CaptureRestartRetryPolicy.maxAttempts),
            .giveUp,
        )
        XCTAssertEqual(
            CaptureRestartRetryPolicy.decide(attemptsSoFar: CaptureRestartRetryPolicy.maxAttempts + 3),
            .giveUp,
        )
    }

    func testLastInBudgetAttemptStillRetries() {
        guard case .retry = CaptureRestartRetryPolicy.decide(attemptsSoFar: CaptureRestartRetryPolicy.maxAttempts - 1) else {
            XCTFail("the final in-budget attempt should retry, not give up")
            return
        }
    }
}
