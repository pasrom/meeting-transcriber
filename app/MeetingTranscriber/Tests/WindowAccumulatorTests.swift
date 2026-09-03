@testable import MeetingTranscriber
import XCTest

/// The report's window arithmetic, without a model or a file.
///
/// This is why the roll-up is a value type rather than three running variables
/// in the streaming loop: the boundary crossing is the part that is easy to get
/// wrong, and every assertion below would otherwise need the C library and a
/// 3 MB model that no CI job has.
final class WindowAccumulatorTests: XCTestCase {
    private let rate = AudioConstants.targetSampleRate

    private func constant(_ value: Float, _ count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    /// Feeds `total` samples through in blocks of `blockSize`.
    private func run(
        blockSize: Int, total: Int,
        mic: Float, reference: Float, output: Float,
    ) -> [EchoCancellationWindow] {
        var accumulator = WindowAccumulator(samplesPerWindow: rate)
        var windows: [EchoCancellationWindow] = []
        var done = 0
        while done < total {
            let take = min(blockSize, total - done)
            accumulator.add(
                mic: constant(mic, take), reference: constant(reference, take),
                output: constant(output, take), into: &windows,
            )
            done += take
        }
        accumulator.flush(into: &windows)
        return windows
    }

    func testOneWindowPerSecondOfAudio() {
        let windows = run(blockSize: rate, total: 5 * rate, mic: 0.5, reference: 0.5, output: 0.5)
        XCTAssertEqual(windows.count, 5)
    }

    /// The invariant the doc comment claims and the reason the window is a
    /// second rather than "whatever a block happens to be": the block size is a
    /// throughput knob, and turning it must not change what the report says.
    /// Blocks here are deliberately not divisors of a window, so every one of
    /// them crosses a boundary somewhere.
    func testTheBlockSizeDoesNotChangeTheWindows() {
        let reference = run(blockSize: rate, total: 4 * rate, mic: 0.5, reference: 0.25, output: 0.05)
        for blockSize in [256, 16384, 3 * rate / 7, 2 * rate] {
            let got = run(blockSize: blockSize, total: 4 * rate, mic: 0.5, reference: 0.25, output: 0.05)
            XCTAssertEqual(got.count, reference.count, "block size \(blockSize) changed the window count")
            // Compared with a tolerance rather than for equality: the same
            // additions in a different grouping is a different rounding, and
            // asserting bit equality would pin the grouping instead of the
            // invariant.
            for (index, pair) in zip(got, reference).enumerated() {
                XCTAssertEqual(
                    pair.0.reductionDb, pair.1.reductionDb, accuracy: 0.001,
                    "block size \(blockSize), window \(index)",
                )
                XCTAssertEqual(
                    pair.0.referenceDBFS, pair.1.referenceDBFS, accuracy: 0.001,
                    "block size \(blockSize), window \(index)",
                )
            }
        }
    }

    /// A recording is almost never a whole number of seconds. Dropping the
    /// remainder would silently lose the end of a short one, which is exactly
    /// where a run has the fewest windows to be judged on.
    func testTheTrailingPartialWindowIsKept() {
        let windows = run(
            blockSize: rate, total: 2 * rate + rate / 4,
            mic: 0.5, reference: 0.5, output: 0.5,
        )
        XCTAssertEqual(windows.count, 3)
    }

    func testNothingIsEmittedForAnEmptyRun() {
        var accumulator = WindowAccumulator(samplesPerWindow: rate)
        var windows: [EchoCancellationWindow] = []
        accumulator.flush(into: &windows)
        XCTAssertTrue(windows.isEmpty)
    }

    /// Half the amplitude out is 6 dB of reduction, and the reference level is
    /// its own dBFS. Pinned on a constant signal so the expected value is
    /// arithmetic rather than a recorded output.
    func testTheLevelsAreTheOnesTheSelfCheckReads() throws {
        let windows = run(blockSize: rate, total: rate, mic: 0.5, reference: 0.25, output: 0.25)
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.reductionDb, 6.0206, accuracy: 0.01)
        XCTAssertEqual(window.referenceDBFS, -12.0412, accuracy: 0.01)
    }

    /// Silence must produce a floor, not a negative infinity that poisons every
    /// comparison downstream. The self-check sorts these and takes a median.
    func testSilenceProducesAFiniteFloorRatherThanInfinity() throws {
        let windows = run(blockSize: rate, total: rate, mic: 0, reference: 0, output: 0)
        let window = try XCTUnwrap(windows.first)
        XCTAssertTrue(window.referenceDBFS.isFinite)
        XCTAssertTrue(window.reductionDb.isFinite)
        // Well under any floor a reader of these windows would set. Written as
        // a number rather than borrowed from the self-check: this file tests
        // the arithmetic, and a policy's constant moving is not a reason for an
        // arithmetic test to fail.
        XCTAssertLessThan(window.referenceDBFS, -100)
    }

    /// The output is the shorter array on a partial trailing hop, and the mic
    /// and reference are read only as far as it goes. A mismatch here used to
    /// be the kind of thing that crashes on the last block of a recording.
    func testAShorterOutputDoesNotReadPastTheOtherArrays() {
        var accumulator = WindowAccumulator(samplesPerWindow: rate)
        var windows: [EchoCancellationWindow] = []
        accumulator.add(
            mic: constant(0.5, 100), reference: constant(0.5, 100),
            output: constant(0.5, 40), into: &windows,
        )
        accumulator.flush(into: &windows)
        XCTAssertEqual(windows.count, 1)
    }
}
