import AudioTapLib
@testable import MeetingTranscriber
import XCTest

final class SampleRateDriftDetectorTests: XCTestCase {
    /// Build a synthetic `LiveAudioBuffer` at offset `seconds` from a
    /// fictional t=0 hostTime, declaring `claimedRate` in the header but
    /// carrying `actualFramesPerCallback` samples. Channels = 1 keeps the
    /// frame arithmetic in the detector simple.
    private func buffer(
        claimedRate: Int,
        actualFramesPerCallback: Int,
        atSeconds seconds: Double,
    ) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: [Float](repeating: 0, count: actualFramesPerCallback),
            channelCount: 1,
            sampleRate: claimedRate,
            hostTime: SampleRateDriftDetector.secondsToMachTicks(seconds),
        )
    }

    func testNoReportWhenObservedMatchesClaimedRate() {
        var detector = SampleRateDriftDetector()
        var report: SampleRateDriftDetector.Report?

        // 5 callbacks every 0.5 s carrying 24000 frames each → observed
        // rate is 48 kHz (which matches the claimed 48 kHz).
        for i in 0 ..< 5 {
            let buf = buffer(
                claimedRate: 48000,
                actualFramesPerCallback: 24000,
                atSeconds: Double(i) * 0.5,
            )
            if let r = detector.observe(buf, now: Date(timeIntervalSince1970: Double(i))) {
                report = r
            }
        }
        XCTAssertNil(report)
    }

    func testReportWhenObservedExceedsThreshold() {
        var detector = SampleRateDriftDetector()
        var report: SampleRateDriftDetector.Report?

        // Header claims 48 kHz; each callback carries 26000 frames every
        // 0.5 s → observed rate = 52 kHz (≈ 8 % drift, past threshold).
        for i in 0 ..< 5 {
            let buf = buffer(
                claimedRate: 48000,
                actualFramesPerCallback: 26000,
                atSeconds: Double(i) * 0.5,
            )
            if let r = detector.observe(buf, now: Date(timeIntervalSince1970: Double(i))) {
                report = r
            }
        }
        XCTAssertNotNil(report)
        if let report {
            XCTAssertEqual(report.claimedRate, 48000.0, accuracy: 0.0001)
            XCTAssertEqual(report.observedRate, 52000.0, accuracy: 100.0)
            XCTAssertGreaterThan(report.driftFraction, SampleRateDriftDetector.driftThreshold)
        }
    }

    func testWarnCooldownSuppressesRepeats() {
        var detector = SampleRateDriftDetector()
        var firedReports: [SampleRateDriftDetector.Report] = []

        // Same drifty stream over a longer span — many callbacks fire,
        // the detector should report only once because every subsequent
        // observation lands inside the 30 s warn cooldown.
        for i in 0 ..< 20 {
            let buf = buffer(
                claimedRate: 48000,
                actualFramesPerCallback: 26000,
                atSeconds: Double(i) * 0.5,
            )
            // `now` advances at the same wall-clock rate as the audio
            // timestamps, so a single 30 s cooldown gates everything.
            let wallClock = Date(timeIntervalSince1970: Double(i) * 0.5)
            if let r = detector.observe(buf, now: wallClock) {
                firedReports.append(r)
            }
        }
        XCTAssertEqual(firedReports.count, 1)
    }

    func testInsufficientBuffersDoesNotReport() {
        var detector = SampleRateDriftDetector()
        // Need at least 4 entries — drift detector should silently
        // accumulate fewer than that without firing.
        for i in 0 ..< 3 {
            let buf = buffer(
                claimedRate: 48000,
                actualFramesPerCallback: 26000,
                atSeconds: Double(i) * 0.5,
            )
            let report = detector.observe(buf, now: Date(timeIntervalSince1970: Double(i)))
            XCTAssertNil(report)
        }
    }

    func testEmptyBufferIsIgnored() {
        var detector = SampleRateDriftDetector()
        let empty = LiveAudioBuffer(
            samples: [], channelCount: 1, sampleRate: 48000, hostTime: 0,
        )
        XCTAssertNil(detector.observe(empty))
    }

    // MARK: - mach-tick helpers (pure)

    /// Round-trip across the helper pair must be exact to within the
    /// representation precision (sub-nanosecond on modern Macs). The
    /// detector compares `hostTime`-derived seconds, so any drift in
    /// these helpers would directly distort the observedRate calculation.
    func testMachTicksRoundTripsThroughHelpers() {
        for seconds in [0.0, 0.001, 0.5, 1.0, 5.0, 60.0, 3600.0] {
            let ticks = SampleRateDriftDetector.secondsToMachTicks(seconds)
            let back = SampleRateDriftDetector.machTicksToSeconds(ticks)
            XCTAssertEqual(back, seconds, accuracy: 0.000_001)
        }
    }

    func testZeroTicksConvertsToZeroSeconds() {
        XCTAssertEqual(SampleRateDriftDetector.machTicksToSeconds(0), 0.0)
    }

    func testZeroSecondsConvertsToZeroTicks() {
        XCTAssertEqual(SampleRateDriftDetector.secondsToMachTicks(0), 0)
    }
}
