@testable import AudioTapLib
import XCTest

/// Characterization tests for `SampleRateQuery.chooseRate` — the pure sample-rate
/// priority ladder (tap > nominal > stream > requested) extracted from the
/// CoreAudio-bound `AppAudioCapture.resolveActualSampleRate`. The mismatch rung
/// preferring nominal over stream is the Bluetooth-HFP-rate guard from the #379
/// family.
final class SampleRateChooseRateTests: XCTestCase {
    // MARK: - Tap rung (most authoritative)

    func testTapRateWinsOverNominalAndStream() {
        let decision = SampleRateQuery.chooseRate(
            tapRate: 48000, nominalRate: 44100, streamRate: 16000, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 48000)
        XCTAssertEqual(decision.source, .tap)
        XCTAssertFalse(decision.differsFromRequested, "48000 == requested → no divergence")
    }

    func testTapRateDiffersFromRequestedIsReportedButUsed() {
        // A valid tap rate that differs from requested is still used (USB/aggregate
        // device negotiated a different rate), and the divergence is flagged.
        let decision = SampleRateQuery.chooseRate(
            tapRate: 44100, nominalRate: 0, streamRate: 0, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 44100, "the queried tap rate is authoritative")
        XCTAssertEqual(decision.source, .tap)
        XCTAssertTrue(decision.differsFromRequested)
    }

    func testImplausibleTapRateFallsBackToRequested() {
        // Tap answers (> 0) but with an implausible rate (> 384 kHz): validation
        // falls back to the requested rate, yet the rung is still the tap.
        let decision = SampleRateQuery.chooseRate(
            tapRate: 500_000, nominalRate: 0, streamRate: 0, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 48000, "implausible queried rate → requested")
        XCTAssertEqual(decision.source, .tap)
        XCTAssertFalse(decision.differsFromRequested, "fallback-to-requested is not a divergence")
    }

    // MARK: - Nominal + stream cross-validation rungs (tap unavailable)

    func testConsistentNominalAndStream() {
        let decision = SampleRateQuery.chooseRate(
            tapRate: 0, nominalRate: 48000, streamRate: 48000, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 48000)
        XCTAssertEqual(decision.source, .consistent)
        XCTAssertFalse(decision.differsFromRequested, "48000 == requested → no divergence")
    }

    func testConsistentButDiffersFromRequested() {
        // Nominal == stream but both differ from requested: the consistent rung
        // must still flag the divergence (the "Aggregate device rate differs"
        // operator warning). Guards the .consistent rung's differ flag, which the
        // equal-to-requested case above cannot exercise.
        let decision = SampleRateQuery.chooseRate(
            tapRate: 0, nominalRate: 44100, streamRate: 44100, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 44100)
        XCTAssertEqual(decision.source, .consistent)
        XCTAssertTrue(decision.differsFromRequested)
    }

    func testMismatchPrefersNominalOverStream() {
        // The #379 guard: an output-scope stream can report a Bluetooth HFP rate
        // (16 kHz). Nominal (44100) must win over stream (16000), and the divergence
        // from the requested 48000 is flagged.
        let decision = SampleRateQuery.chooseRate(
            tapRate: 0, nominalRate: 44100, streamRate: 16000, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 44100, "nominal must win over the (possibly BT HFP) stream rate")
        XCTAssertEqual(decision.source, .mismatchPreferNominal)
        XCTAssertTrue(decision.differsFromRequested)
    }

    func testOnlyNominalAvailable() {
        let decision = SampleRateQuery.chooseRate(
            tapRate: 0, nominalRate: 44100, streamRate: 0, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 44100)
        XCTAssertEqual(decision.source, .onlyNominal)
        XCTAssertTrue(decision.differsFromRequested)
    }

    func testOnlyStreamAvailable() {
        let decision = SampleRateQuery.chooseRate(
            tapRate: 0, nominalRate: 0, streamRate: 44100, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 44100)
        XCTAssertEqual(decision.source, .onlyStream)
        XCTAssertTrue(decision.differsFromRequested)
    }

    func testNothingQueryableUsesRequested() {
        let decision = SampleRateQuery.chooseRate(
            tapRate: 0, nominalRate: 0, streamRate: 0, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 48000)
        XCTAssertEqual(decision.source, .requestedFallback)
        XCTAssertFalse(decision.differsFromRequested)
    }
}
