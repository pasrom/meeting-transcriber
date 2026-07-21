@testable import MeetingTranscriber
import XCTest

final class BrowserConsentPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFirstContactAsks() {
        let policy = BrowserConsentPolicy()
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0), .ask)
    }

    func testDeclineSuppressesWithinCooldown() {
        var policy = BrowserConsentPolicy(cooldown: 60)
        policy.recordDecline(app: "Google Chrome", now: t0)
        // Still inside the 60 s window → suppressed until t0+60.
        XCTAssertEqual(
            policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(59)),
            .suppressed(until: t0.addingTimeInterval(60)),
        )
    }

    func testAsksAgainAtCooldownBoundary() {
        var policy = BrowserConsentPolicy(cooldown: 60)
        policy.recordDecline(app: "Google Chrome", now: t0)
        // At exactly t0+60 the window has elapsed → ask again.
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(60)), .ask)
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(120)), .ask)
    }

    func testCooldownIsPerApp() {
        var policy = BrowserConsentPolicy(cooldown: 60)
        policy.recordDecline(app: "Google Chrome", now: t0)
        // A decline for one app does not suppress another.
        XCTAssertEqual(policy.decision(app: "Microsoft Edge", now: t0.addingTimeInterval(1)), .ask)
    }

    func testCustomCooldownRespected() {
        var policy = BrowserConsentPolicy(cooldown: 10)
        policy.recordDecline(app: "Google Chrome", now: t0)
        XCTAssertEqual(
            policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(9)),
            .suppressed(until: t0.addingTimeInterval(10)),
        )
        XCTAssertEqual(policy.decision(app: "Google Chrome", now: t0.addingTimeInterval(10)), .ask)
    }
}
