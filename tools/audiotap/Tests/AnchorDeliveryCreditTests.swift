@testable import AudioTapLib
import XCTest

/// When an anchor has earned a place in the search's memory.
///
/// The case that matters is the dead track with stray energy: a 44.7-minute
/// call that was 1.9% nonzero samples still contained energy in 55 of its 530
/// five-second windows. Crediting on a lone nonzero sample would have recorded
/// that dead anchor as good, and the memory meant to rescue the next recording
/// would have pointed back at the device that lost this one.
final class AnchorDeliveryCreditTests: XCTestCase {
    private let bufferSamples = 1024
    private let step: TimeInterval = 0.02

    /// Feed `seconds` of buffers whose samples are a `zeroFraction` share
    /// exactly zero, returning how many completed intervals earned credit.
    @discardableResult
    private func feed(
        _ credit: inout AnchorDeliveryCredit,
        zeroFraction: Double,
        seconds: TimeInterval,
        from start: TimeInterval = 0,
    ) -> Int {
        var earned = 0
        var now = start
        let end = start + seconds
        let zeros = Int((Double(bufferSamples) * zeroFraction).rounded())
        while now <= end {
            if credit.observe(zeroSamples: zeros, samples: bufferSamples, now: now) { earned += 1 }
            now += step
        }
        return earned
    }

    // MARK: - The regression

    /// The dead track's live windows are about 82% zeros — its 1.9% nonzero
    /// samples spread across the 10.4% of its duration that carried any. That
    /// must not be mistaken for a working anchor.
    func testADeadTracksStrayEnergyDoesNotEarnCredit() {
        var credit = AnchorDeliveryCredit()
        let earned = feed(&credit, zeroFraction: 0.82, seconds: 60)
        XCTAssertEqual(earned, 0, "an anchor that is 82% silent has not demonstrated delivery")
    }

    /// A single nonzero sample in an otherwise dead interval is the exact input
    /// the first version credited on.
    func testALoneNonzeroSampleDoesNotEarnCredit() {
        var credit = AnchorDeliveryCredit()
        var earned = 0
        var now: TimeInterval = 0
        while now <= 60 {
            let zeros = now == 10 ? bufferSamples - 1 : bufferSamples
            if credit.observe(zeroSamples: zeros, samples: bufferSamples, now: now) { earned += 1 }
            now += step
        }
        XCTAssertEqual(earned, 0)
    }

    // MARK: - A working anchor

    func testAnAnchorCarryingAudioEarnsCredit() {
        var credit = AnchorDeliveryCredit()
        XCTAssertGreaterThan(feed(&credit, zeroFraction: 0, seconds: 30), 0)
    }

    /// A healthy anchor is not continuously loud — conversation has gaps — so
    /// credit must not require a spotless interval.
    func testAHealthyAnchorWithNormalGapsEarnsCredit() {
        var credit = AnchorDeliveryCredit()
        XCTAssertGreaterThan(feed(&credit, zeroFraction: 0.417, seconds: 60), 0)
    }

    func testCreditIsNotEarnedBeforeAnIntervalCompletes() {
        var credit = AnchorDeliveryCredit()
        XCTAssertEqual(feed(&credit, zeroFraction: 0, seconds: 4), 0)
    }

    func testThresholdSitsBelowTheDeadTracksLiveWindows() {
        XCTAssertLessThan(
            AnchorDeliveryCredit.defaultMaxZeroFraction, 0.82,
            "credit must reject the stray-energy windows of a dead track",
        )
        XCTAssertGreaterThan(
            AnchorDeliveryCredit.defaultMaxZeroFraction, 0.417,
            "credit must accept a healthy anchor at its idle ceiling",
        )
    }

    // MARK: - Interval handling

    /// A verdict is about audio just heard. Once an anchor goes quiet, credit
    /// must stop — a good stretch cannot keep vouching for it.
    ///
    /// The transition interval itself is allowed to earn credit: it genuinely
    /// contains audio, and the anchor genuinely was delivering moments earlier.
    /// What must not happen is credit continuing once the silence is the whole
    /// story, so the assertion is on the steady state rather than the boundary.
    func testAGoodStretchDoesNotKeepCreditingAfterTheAnchorGoesQuiet() {
        var credit = AnchorDeliveryCredit()
        feed(&credit, zeroFraction: 0, seconds: 30)
        // Continuous, as production buffers are — no observation gap, which
        // would let a completed interval span stale samples.
        feed(&credit, zeroFraction: 1, seconds: 30, from: 30 + step)
        let earnedOnceDead = feed(&credit, zeroFraction: 1, seconds: 30, from: 60 + step)
        XCTAssertEqual(earnedOnceDead, 0)
    }

    func testResetAbandonsTheIntervalInProgress() {
        var credit = AnchorDeliveryCredit()
        feed(&credit, zeroFraction: 0, seconds: 4)
        credit.reset()
        XCTAssertEqual(
            feed(&credit, zeroFraction: 0, seconds: 4, from: 5), 0,
            "a new anchor's interval must start empty",
        )
    }

    func testEmptyBuffersAreIgnored() {
        var credit = AnchorDeliveryCredit()
        for tick in 0 ..< 100 {
            XCTAssertFalse(credit.observe(zeroSamples: 0, samples: 0, now: Double(tick)))
        }
    }
}
