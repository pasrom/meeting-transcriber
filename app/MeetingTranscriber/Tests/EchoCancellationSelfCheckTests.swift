@testable import MeetingTranscriber
import XCTest

/// Did the cancellation actually do anything?
///
/// The question exists because the answer is sometimes no, silently: on a
/// minority of recordings the model removes nothing at all while removing tens
/// of decibels from the same echo presented on its own. Compiling, the tests,
/// and both builds stay green through that, and the user gets a recording with
/// the echo still in it and no reason to suspect anything.
final class EchoCancellationSelfCheckTests: XCTestCase {
    private func window(reference: Float, reduction: Float) -> EchoCancellationWindow {
        EchoCancellationWindow(referenceDBFS: reference, reductionDb: reduction)
    }

    private func report(
        _ windows: [(Float, Float)],
    ) -> EchoCancellationReport {
        EchoCancellationReport(windows: windows.map { window(reference: $0.0, reduction: $0.1) })
    }

    /// A healthy run: it empties the windows carrying echo and leaves the rest
    /// where they were.
    func testAHealthyRunTookEffect() {
        var windows = (0 ..< 30).map { _ in (Float(-20), Float(28)) }
        windows += (0 ..< 20).map { _ in (Float(-80), Float(0.3)) }
        XCTAssertEqual(EchoCancellationSelfCheck.effect(of: report(windows)), .removed)
    }

    /// The measured failure shape: the run completes, writes a full-length
    /// track, and takes about a tenth of a decibel off it.
    func testARunThatRemovedNothingDidNotTakeEffect() {
        var windows = (0 ..< 30).map { _ in (Float(-20), Float(0.2)) }
        windows += (0 ..< 20).map { _ in (Float(-80), Float(0.1)) }
        XCTAssertEqual(EchoCancellationSelfCheck.effect(of: report(windows)), .ineffective)
    }

    /// The reason this is a difference and not a level. A run that simply
    /// halves the microphone reports six decibels of "reduction" in every
    /// window carrying echo, and leaves that echo exactly as audible next to
    /// the local voice as it was. Against a level it passes; against the
    /// windows that carried no echo it does not.
    func testUniformAttenuationIsNotRemoval() {
        var windows = (0 ..< 30).map { _ in (Float(-20), Float(6)) }
        windows += (0 ..< 20).map { _ in (Float(-80), Float(6)) }
        XCTAssertEqual(EchoCancellationSelfCheck.effect(of: report(windows)), .ineffective)
    }

    /// A difference rewards anything that pushes the two groups apart, and
    /// amplifying the control group does exactly that. This run barely clears
    /// the level test and boosts the windows where the local speaker is alone
    /// by twenty decibels; the difference alone would call that a success.
    func testAmplifyingTheControlGroupIsNotRemoval() {
        var windows = (0 ..< 15).map { _ in (Float(-20), Float(3.5)) }
        windows += (0 ..< 15).map { _ in (Float(-80), Float(-20)) }
        XCTAssertEqual(
            EchoCancellationSelfCheck.effect(of: report(windows)), .damagedControl,
            "not .ineffective: it may have removed plenty, and damage is why it was refused",
        )
    }

    /// Healthy runs do attenuate the control a little, occasionally by a lot,
    /// and that must not be confused with amplifying it. The difference is
    /// what shrinks; the run is still judged on it.
    func testAttenuatingTheControlGroupIsJudgedOnTheDifference() {
        var windows = (0 ..< 15).map { _ in (Float(-20), Float(30)) }
        windows += (0 ..< 15).map { _ in (Float(-80), Float(10)) }
        XCTAssertEqual(EchoCancellationSelfCheck.effect(of: report(windows)), .removed)
    }

    /// A far end that never stops leaves nothing to compare against, and that
    /// is precisely the case where broad attenuation and cancellation look the
    /// same. Withheld rather than waved through.
    func testAReferenceThatNeverStopsYieldsNoVerdict() {
        let windows = (0 ..< 40).map { _ in (Float(-20), Float(28)) }
        XCTAssertEqual(EchoCancellationSelfCheck.effect(of: report(windows)), .indeterminate)
    }

    /// The same missing control, with a low reduction this time. It has to
    /// stay indeterminate rather than becoming a measured failure: the two
    /// send the user to different places, and nobody measured this one.
    func testAMissingControlIsNeverReportedAsAMeasuredFailure() {
        let windows = (0 ..< 40).map { _ in (Float(-20), Float(0.2)) }
        XCTAssertEqual(EchoCancellationSelfCheck.effect(of: report(windows)), .indeterminate)
    }

    /// Windows where the far end is not playing carry no echo to remove, so a
    /// canceller correctly doing nothing in them must not be counted against
    /// it. They are the control, not part of the measurement.
    func testQuietReferenceWindowsAreTheControlNotTheMeasurement() {
        var windows = (0 ..< 40).map { _ in (Float(-80), Float(0)) }
        windows += (0 ..< 15).map { _ in (Float(-20), Float(28)) }
        XCTAssertEqual(EchoCancellationSelfCheck.effect(of: report(windows)), .removed)
    }

    /// Too little far-end audio to judge is its own answer. A verdict from
    /// three windows would be a coin toss reported as a fact.
    func testTooFewScoredWindowsAreIndeterminate() {
        var windows = (0 ..< 5).map { _ in (Float(-20), Float(0.1)) }
        windows += (0 ..< 20).map { _ in (Float(-80), Float(0.1)) }
        XCTAssertEqual(EchoCancellationSelfCheck.effect(of: report(windows)), .indeterminate)
    }

    func testAnEmptyReportIsIndeterminate() {
        XCTAssertEqual(
            EchoCancellationSelfCheck.effect(of: EchoCancellationReport(windows: [])),
            .indeterminate,
        )
    }

    /// The threshold has to leave room on both sides. Above zero, or a run
    /// that removed nothing would pass; below the floor a healthy model clears
    /// on the synthetic probe the bundle check uses, or a working run could
    /// fail. Sourced from a constant that ships in the repository rather than
    /// from a corpus a reader cannot open.
    func testTheThresholdLeavesRoomOnBothSides() {
        XCTAssertGreaterThan(EchoCancellationSelfCheck.minMedianReductionDb, 0)
        XCTAssertLessThan(
            EchoCancellationSelfCheck.minMedianReductionDb,
            EchoReductionVerdict.minReductionDb,
        )
    }
}
