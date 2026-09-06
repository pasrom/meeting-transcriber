@testable import AudioTapLib
import XCTest

/// Characterization tests for `SampleRateQuery.chooseRate`, the pure sample-rate
/// decision extracted from the CoreAudio-bound
/// `AppAudioCapture.resolveActualSampleRate`.
///
/// Calling it a ladder of nominal > stream > requested reads well and is wrong
/// in one place that matters: the output-stream format is never adopted on its
/// own. It corroborates the nominal rate, and its disagreement is a warning, but
/// a lone answer from it falls back to the requested rate, because it is the
/// property that reports a Bluetooth HFP link rate (#82, #379 family). So the
/// rates it can produce are nominal or requested, nothing else.
///
/// There is no tap rung either: a mixdown tap's format is a constant (#683).
final class SampleRateChooseRateTests: XCTestCase {
    // MARK: - Nominal + stream cross-validation rungs

    func testConsistentNominalAndStream() {
        let decision = SampleRateQuery.chooseRate(
            nominalRate: 48000, streamRate: 48000, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 48000)
        XCTAssertEqual(decision.source, .consistent)
    }

    func testConsistentButDiffersFromRequested() {
        // Nominal == stream but both differ from requested: the device rate
        // wins, because "requested" is only a fallback default. Guards the
        // .consistent rung's differ
        // flag, which the equal-to-requested case above cannot exercise. This is
        // the 44.1 kHz device of issue #683, which the tap rung used to hide.
        let decision = SampleRateQuery.chooseRate(
            nominalRate: 44100, streamRate: 44100, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 44100)
        XCTAssertEqual(decision.source, .consistent)
    }

    func testConsistentAboveTheRequestedRate() {
        // The measured 96 kHz row of issue #683: a device above the default rate
        // is as legitimate as one below it, and must not be clamped or snapped.
        let decision = SampleRateQuery.chooseRate(
            nominalRate: 96000, streamRate: 96000, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 96000)
        XCTAssertEqual(decision.source, .consistent)
    }

    func testMismatchPrefersNominalOverStream() {
        // The #379 guard: an output-scope stream can report a Bluetooth HFP rate
        // (16 kHz). Nominal (44100) must win over stream (16000), and the disagreement
        // from the requested 48000 is flagged.
        let decision = SampleRateQuery.chooseRate(
            nominalRate: 44100, streamRate: 16000, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 44100, "nominal must win over the (possibly BT HFP) stream rate")
        XCTAssertEqual(decision.source, .mismatchPreferNominal)
    }

    func testOnlyNominalAvailable() {
        let decision = SampleRateQuery.chooseRate(
            nominalRate: 44100, streamRate: 0, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 44100)
        XCTAssertEqual(decision.source, .onlyNominal)
    }

    func testTheStreamFormatIsNeverTheAnswerOnItsOwn() {
        // The ladder already distrusts this property when the two disagree: the
        // mismatch rung takes nominal because an output-scope stream can report
        // a Bluetooth HFP link rate rather than the delivery rate. Issue #82 is
        // that case, and its own fix commit called this selector "wrong scope".
        //
        // Trusting the same property completely the moment nominal goes quiet
        // was the inconsistency. On main it was unreachable, because the tap
        // rung short-circuited both device reads; removing that rung exposed
        // it. So it falls back to the requested rate and says why, and the
        // first-callback measurement corrects whatever the truth turns out to
        // be. Adopting 24000 for buffers arriving at 48000 is the failure
        // issue #82 was filed for.
        let decision = SampleRateQuery.chooseRate(
            nominalRate: 0, streamRate: 24000, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 48000, "a lone stream answer must not be adopted")
        XCTAssertEqual(decision.source, .streamOnlyDistrusted)
    }

    // MARK: - Fallbacks

    func testNothingQueryableUsesRequested() {
        let decision = SampleRateQuery.chooseRate(
            nominalRate: 0, streamRate: 0, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 48000)
        XCTAssertEqual(decision.source, .requestedFallback)
    }

    func testImplausibleNominalRateFallsBackToRequested() {
        // A device answers (> 0) but with an implausible rate (> 384 kHz):
        // validation falls back to the requested rate, yet the source still
        // names the rung that answered, so the caller's diagnostics say which
        // property produced the nonsense.
        let decision = SampleRateQuery.chooseRate(
            nominalRate: 500_000, streamRate: 0, requestedRate: 48000,
        )

        XCTAssertEqual(decision.rate, 48000, "implausible queried rate → requested")
        XCTAssertEqual(decision.source, .onlyNominal)
    }
}
