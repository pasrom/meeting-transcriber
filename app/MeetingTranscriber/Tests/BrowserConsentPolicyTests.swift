@testable import MeetingTranscriber
import XCTest

final class BrowserConsentPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - An unanswered prompt is not a "no" (issue #543)

    /// Saying no and never seeing the question are different answers, and they
    /// used to share one cooldown. An explicit Ignore has to stick, or the
    /// prompt returns while the user is still in the call they just declined.
    func testExplicitDeclineUsesTheLongCooldown() {
        var policy = BrowserConsentPolicy(declineCooldown: 600, expiryCooldown: 60)
        policy.recordDecline(app: "Google Chrome", now: t0)
        XCTAssertEqual(
            policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(599)),
            .suppressed(until: t0.addingTimeInterval(600)),
        )
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(600)), .ask)
    }

    /// A prompt nobody answered means the user was away, not that they said no,
    /// so the next call must be able to ask again soon.
    func testExpiryUsesTheShortCooldown() {
        var policy = BrowserConsentPolicy(declineCooldown: 600, expiryCooldown: 60)
        policy.recordExpiry(app: "Google Chrome", now: t0)
        XCTAssertEqual(
            policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(59)),
            .suppressed(until: t0.addingTimeInterval(60)),
        )
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(60)), .ask)
    }

    /// The defaults are the product decision, not an implementation detail:
    /// ten minutes after a no, one minute after silence.
    func testDefaultsFavourTheExplicitAnswer() {
        let policy = BrowserConsentPolicy()
        XCTAssertEqual(policy.declineCooldown, 600)
        XCTAssertEqual(policy.expiryCooldown, 60)
    }

    func testFirstContactAsks() {
        let policy = BrowserConsentPolicy()
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0), .ask)
    }

    func testDeclineSuppressesWithinCooldown() {
        var policy = BrowserConsentPolicy(declineCooldown: 60, expiryCooldown: 60)
        policy.recordDecline(app: "Google Chrome", now: t0)
        // Still inside the 60 s window → suppressed until t0+60.
        XCTAssertEqual(
            policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(59)),
            .suppressed(until: t0.addingTimeInterval(60)),
        )
    }

    func testAsksAgainAtCooldownBoundary() {
        var policy = BrowserConsentPolicy(declineCooldown: 60, expiryCooldown: 60)
        policy.recordDecline(app: "Google Chrome", now: t0)
        // At exactly t0+60 the window has elapsed → ask again.
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(60)), .ask)
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(120)), .ask)
    }

    func testCooldownIsPerApp() {
        var policy = BrowserConsentPolicy(declineCooldown: 60, expiryCooldown: 60)
        policy.recordDecline(app: "Google Chrome", now: t0)
        // A decline for one app does not suppress another.
        XCTAssertEqual(policy.decision(app: "Microsoft Edge", now: t0.addingTimeInterval(1)), .ask)
    }

    func testCustomCooldownRespected() {
        var policy = BrowserConsentPolicy(declineCooldown: 10, expiryCooldown: 10)
        policy.recordDecline(app: "Google Chrome", now: t0)
        XCTAssertEqual(
            policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(9)),
            .suppressed(until: t0.addingTimeInterval(10)),
        )
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(10)), .ask)
    }
}
