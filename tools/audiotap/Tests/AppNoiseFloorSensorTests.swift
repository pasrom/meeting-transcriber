@testable import AudioTapLib
import Darwin
import XCTest

/// The app-audio noise-floor sensor (issue #699): a tap carrying only a level
/// below one 16-bit step for two minutes is reported, while the shared energy
/// definition stays "any non-zero sample".
///
/// The first group drives the real capture path, `accumulateDebugRMS`, with
/// raw Float32 buffers the way the IOProc does. The second pins the fractions
/// on the sensor itself, with its production constants, because exact shares
/// are easier to build there than out of sample values.
@available(macOS 14.2, *)
final class AppNoiseFloorSensorTests: XCTestCase {
    private var devNullFD: Int32 = -1
    /// One 16-bit step, written out rather than read from the sensor, so a
    /// moved threshold cannot move the fixtures with it.
    private let step = 1.0 / 32768.0
    private let t0: TimeInterval = 1000

    override func setUp() {
        super.setUp()
        devNullFD = open("/dev/null", O_WRONLY)
        XCTAssertGreaterThanOrEqual(devNullFD, 0, "couldn't open /dev/null")
    }

    override func tearDown() {
        if devNullFD >= 0 { close(devNullFD) }
        devNullFD = -1
        super.tearDown()
    }

    /// The capture's clock seam, the one its watchdog reads too.
    private final class Clock: @unchecked Sendable {
        var now: TimeInterval = 0
    }

    private let clock = Clock()

    private func makeCapture() -> AppAudioCapture {
        let clock = clock
        let readClock: @Sendable () -> TimeInterval = { clock.now }
        return AppAudioCapture(pids: [], outputFileDescriptor: devNullFD, attemptBody: nil, clockOverride: readClock)
    }

    /// Feeds 10 ms stereo buffers of one constant sample value from `start`
    /// up to (not including) `end`, as the IOProc would hand them over.
    private func feed(_ capture: AppAudioCapture, value: Float, from start: TimeInterval, to end: TimeInterval) {
        var samples = [Float](repeating: value, count: 960)
        let byteCount = samples.count * MemoryLayout<Float>.size
        clock.now = start
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return XCTFail("no base") }
            while clock.now < end {
                capture.accumulateDebugRMS(data: UnsafeMutableRawPointer(base), byteCount: byteCount)
                clock.now += 0.01
            }
        }
    }

    /// -98.5 dBFS, the floor measured in the issue.
    private var issueFloor: Float {
        Float(pow(10.0, -98.5 / 20.0))
    }

    // MARK: - Through the capture path

    func testTheIssueFloorIsReportedOnceAFullWindowHasPassed() {
        let capture = makeCapture()
        feed(capture, value: issueFloor, from: t0, to: t0 + 119.9)
        XCTAssertFalse(capture.carriesOnlyNoiseFloor, "a verdict waits for the full two minutes")
        feed(capture, value: issueFloor, from: t0 + 119.9, to: t0 + 120.1)
        XCTAssertTrue(capture.carriesOnlyNoiseFloor)
    }

    func testAFloorJustBelowOneStepIsReported() {
        let capture = makeCapture()
        feed(capture, value: Float(step * 0.99), from: t0, to: t0 + 121)
        XCTAssertTrue(capture.carriesOnlyNoiseFloor)
    }

    /// The step itself is the smallest level a 16-bit track can hold, so a
    /// buffer at it is signal.
    func testALevelOfExactlyOneStepIsSignal() {
        let capture = makeCapture()
        feed(capture, value: Float(step), from: t0, to: t0 + 200)
        XCTAssertFalse(capture.carriesOnlyNoiseFloor)
    }

    /// A tap of a silent meeting app delivers exact zeros. They count as zero
    /// here too; the monitor decides which report a window of them gets.
    func testExactZerosCountAsZero() {
        let capture = makeCapture()
        feed(capture, value: 0, from: t0, to: t0 + 121)
        XCTAssertTrue(capture.carriesOnlyNoiseFloor)
    }

    /// After a gap in delivery the window holds only what came since. A few
    /// buffers after a gap are not two minutes of evidence, however long ago
    /// the first buffer of the recording arrived.
    func testAfterAGapInDeliveryAVerdictWaitsForAFullWindowAgain() {
        let capture = makeCapture()
        feed(capture, value: 0.05, from: t0, to: t0 + 100)
        feed(capture, value: issueFloor, from: t0 + 400, to: t0 + 402)
        XCTAssertFalse(capture.carriesOnlyNoiseFloor, "two seconds after a gap")
        feed(capture, value: issueFloor, from: t0 + 402, to: t0 + 521)
        XCTAssertTrue(capture.carriesOnlyNoiseFloor)
    }

    func testRealAudioIsNotReported() {
        let capture = makeCapture()
        feed(capture, value: 0.05, from: t0, to: t0 + 200)
        XCTAssertFalse(capture.carriesOnlyNoiseFloor)
    }

    func testAudioComingBackClearsTheVerdict() {
        let capture = makeCapture()
        feed(capture, value: issueFloor, from: t0, to: t0 + 121)
        XCTAssertTrue(capture.carriesOnlyNoiseFloor, "precondition")
        feed(capture, value: 0.05, from: t0 + 121, to: t0 + 241)
        XCTAssertFalse(capture.carriesOnlyNoiseFloor)
    }

    /// The decision is that the floor counts as zero for this warning only.
    /// The level publisher still sees a sub-step buffer as carrying energy,
    /// so the digital-silence report, the microphone channel and the
    /// silent-track watchdog keep judging exactly as before.
    func testTheSharedEnergyDefinitionStillCountsTheFloorAsEnergy() throws {
        let capture = makeCapture()
        feed(capture, value: issueFloor, from: t0, to: t0 + 121)
        capture.publishCurrentLevel()
        XCTAssertTrue(capture.carriesOnlyNoiseFloor, "precondition")
        let energyAge = try XCTUnwrap(capture.currentSignalAges.secondsSinceLastEnergy)
        XCTAssertLessThan(energyAge, 1)
    }

    // MARK: - The fractions, on the sensor

    /// One observation per second: a loud part, then a part below the step,
    /// `zeroPercent` of 100 samples in all. Loud first, so a second is at
    /// its exact share once its last buffer is in.
    private func feedSeconds(
        _ sensor: inout AppNoiseFloorSensor, zeroPercent: Int, from start: Int, count: Int,
    ) {
        for second in start ..< start + count {
            let now = TimeInterval(second)
            let loud = 100 - zeroPercent
            if loud > 0 { sensor.observe(sumOfSquares: Double(loud), samples: loud, now: now) }
            if zeroPercent > 0 { sensor.observe(sumOfSquares: 0, samples: zeroPercent, now: now) }
        }
    }

    func testAFullWindowAtNinetyPercentIsReported() {
        var sensor = AppNoiseFloorSensor()
        feedSeconds(&sensor, zeroPercent: 90, from: 1000, count: 121)
        XCTAssertTrue(sensor.isFloorOnly)
    }

    func testAFullWindowAtEightyNinePercentIsNot() {
        var sensor = AppNoiseFloorSensor()
        feedSeconds(&sensor, zeroPercent: 89, from: 1000, count: 300)
        XCTAssertFalse(sensor.isFloorOnly)
    }

    /// Hysteresis: a raised flag holds while the window stays above half, so
    /// a share hovering near the trip point does not flip it buffer by buffer.
    func testARaisedFlagHoldsAboveHalfAndClearsAtHalf() {
        var sensor = AppNoiseFloorSensor()
        feedSeconds(&sensor, zeroPercent: 100, from: 1000, count: 121)
        XCTAssertTrue(sensor.isFloorOnly, "precondition")
        feedSeconds(&sensor, zeroPercent: 51, from: 1121, count: 300)
        XCTAssertTrue(sensor.isFloorOnly, "51% is above the clear point")
        feedSeconds(&sensor, zeroPercent: 50, from: 1421, count: 300)
        XCTAssertFalse(sensor.isFloorOnly)
    }

    /// The window rolls: two minutes of audio at the start do not dilute a
    /// floor that follows them for the rest of the call.
    func testEarlierAudioLeavesTheWindow() {
        var sensor = AppNoiseFloorSensor()
        feedSeconds(&sensor, zeroPercent: 0, from: 1000, count: 600)
        feedSeconds(&sensor, zeroPercent: 100, from: 1600, count: 121)
        XCTAssertTrue(sensor.isFloorOnly)
    }
}
