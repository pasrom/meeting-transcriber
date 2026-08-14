@testable import MeetingTranscriber
import XCTest

/// Pins `EchoBleedDetector`, the decision function behind the "your loudspeaker
/// output is coming back through the microphone" warning.
///
/// Thresholds here are not taste. They come from measuring 86 dual-source pairs:
/// among recordings of meeting length, the affected ones carried 34 %, 60 % and
/// 77 % of their windows above a per-window correlation of 0.7, one borderline
/// case sat at 4 %, and twenty clean recordings sat at exactly 0 %. The share is
/// what separates; the window maximum alone does not, because clean recordings
/// reach 0.3 to 0.55 and the borderline case peaks at 0.875.
final class EchoBleedDetectorTests: XCTestCase {
    private let rate = 16000

    /// Deterministic pseudo-noise; a fixed seed keeps the assertions stable.
    private func noise(seconds: Double, seed: UInt64) -> [Float] {
        var state = seed
        return (0 ..< Int(Double(rate) * seconds)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 33))) / Float(Int32.max)
        }
    }

    /// Speech-like: noise shaped by a slow **aperiodic** envelope.
    ///
    /// Two properties matter and both were learned the hard way. The envelope
    /// has to vary with the seed, not just the carrier, or two supposedly
    /// independent talkers correlate at exactly 1.0 because the detector
    /// compares envelopes. And it must not be periodic: a sine envelope
    /// correlates with itself at every multiple of its period, so a copy
    /// delayed far outside the search window is still "found", which made the
    /// lag-boundary test pass for the wrong reason.
    private func speechLike(seconds: Double, seed: UInt64) -> [Float] {
        var state = seed &+ 1
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(UInt32(truncatingIfNeeded: state >> 33)) / Double(UInt32.max)
        }
        // One envelope control point per 120 ms, linearly interpolated: syllable
        // rhythm without a period to lock onto.
        let step = Int(0.12 * Double(rate))
        let points = (0 ... (Int(Double(rate) * seconds) / step + 2)).map { _ in
            let v = next()
            return v < 0.35 ? 0.0 : v // pauses
        }
        return (0 ..< Int(Double(rate) * seconds)).map { i in
            let carrier = Float(next() * 2 - 1)
            let idx = i / step
            let frac = Double(i % step) / Double(step)
            let env = points[idx] * (1 - frac) + points[idx + 1] * frac
            return carrier * Float(env)
        }
    }

    /// The room path: attenuated and delayed.
    private func bleed(_ source: [Float], delayMs: Double, gain: Float) -> [Float] {
        let d = Int(delayMs / 1000 * Double(rate))
        var out = [Float](repeating: 0, count: source.count)
        for i in d ..< source.count {
            out[i] = source[i - d] * gain
        }
        return out
    }

    // MARK: - The two populations

    func testFullBleedIsDetected() throws {
        let app = speechLike(seconds: 60, seed: 1)
        let mic = bleed(app, delayMs: 15, gain: 0.5)

        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertGreaterThan(result.affectedWindowShare, 0.9, "a pure room copy must light up nearly every window")
        XCTAssertTrue(result.isAffected)
    }

    func testIndependentTracksAreNotDetected() throws {
        let app = speechLike(seconds: 60, seed: 2)
        let mic = speechLike(seconds: 60, seed: 99)

        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertLessThan(result.affectedWindowShare, 0.1, "unrelated speakers must not look like bleed")
        XCTAssertFalse(result.isAffected)
    }

    /// The case the corpus actually contains: bleed for part of the meeting.
    /// Three affected recordings sat at 34 % to 77 %.
    func testPartialBleedAboveTheShareThresholdIsDetected() throws {
        let app = speechLike(seconds: 100, seed: 3)
        var mic = speechLike(seconds: 100, seed: 77)
        let copy = bleed(app, delayMs: 15, gain: 0.5)
        // First 40 s bleed, rest independent.
        for i in 0 ..< (40 * rate) {
            mic[i] = copy[i]
        }

        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertGreaterThan(result.affectedWindowShare, 0.3)
        XCTAssertTrue(result.isAffected)
    }

    /// The borderline recording in the corpus sat at 4 % and must stay quiet,
    /// otherwise the warning proposes altering audio over a single stray window.
    func testIsolatedBleedWindowStaysBelowTheThreshold() throws {
        let app = speechLike(seconds: 200, seed: 4)
        var mic = speechLike(seconds: 200, seed: 55)
        let copy = bleed(app, delayMs: 15, gain: 0.5)
        for i in 0 ..< (8 * rate) {
            mic[i] = copy[i]
        }

        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertLessThan(result.affectedWindowShare, EchoBleedDetector.affectedShareThreshold)
        XCTAssertFalse(result.isAffected)
    }

    // MARK: - No verdict is better than a wrong one

    func testSilentAppTrackYieldsNoVerdict() {
        let app = [Float](repeating: 0, count: 60 * rate)
        let mic = speechLike(seconds: 60, seed: 5)
        XCTAssertNil(
            EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate),
            "a dead channel cannot bleed anywhere; that is a different defect",
        )
    }

    func testSilentMicTrackYieldsNoVerdict() {
        let app = speechLike(seconds: 60, seed: 6)
        let mic = [Float](repeating: 0, count: 60 * rate)
        XCTAssertNil(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
    }

    func testRecordingShorterThanOneWindowYieldsNoVerdict() {
        let app = speechLike(seconds: 4, seed: 7)
        let mic = bleed(app, delayMs: 15, gain: 0.5)
        XCTAssertNil(
            EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate),
            "a share over fewer than one window is not a measurement",
        )
    }

    func testMismatchedLengthsUseTheOverlap() throws {
        let app = speechLike(seconds: 60, seed: 8)
        let mic = Array(bleed(app, delayMs: 15, gain: 0.5).prefix(30 * rate))
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertTrue(result.isAffected)
    }

    // MARK: - The boundaries the constants live on

    /// Bleed at a delay inside the search window is still bleed.
    func testDelayInsideTheLagWindowIsDetected() throws {
        let app = speechLike(seconds: 60, seed: 21)
        let mic = bleed(app, delayMs: 150, gain: 0.5) // maxLagSeconds is 0.2
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertTrue(result.isAffected)
    }

    /// The failure this guards is invisible: a mic that starts late puts real
    /// bleed outside the search window and the recording reads as clean. The
    /// recorder knows the offset, so passing it must restore detection.
    func testDelayBeyondTheLagWindowNeedsMicDelayToBeFound() throws {
        let app = speechLike(seconds: 60, seed: 22)
        let mic = bleed(app, delayMs: 500, gain: 0.5)

        let blind = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertFalse(blind.isAffected, "500 ms is outside the +/-200 ms window, so nothing is found")

        let informed = try XCTUnwrap(EchoBleedDetector.analyse(
            app: app, mic: mic, sampleRate: rate, micDelay: 0.5,
        ))
        XCTAssertTrue(informed.isAffected, "centred on the known offset, the same bleed is found")
    }

    /// Two windows cannot carry a share: the value is quantised to 0, 50 or
    /// 100 %, so a single coincidence would read as a confident verdict.
    func testTooFewWindowsWithholdsTheVerdict() throws {
        let app = speechLike(seconds: 25, seed: 23)
        let mic = bleed(app, delayMs: 15, gain: 0.5)
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertEqual(result.windowsScored, 2)
        XCTAssertGreaterThan(result.affectedWindowShare, 0.9, "the windows themselves do correlate")
        XCTAssertFalse(result.isAffected, "but two windows are not enough to claim it")
    }

    /// Real conversation is not two independent signals: both sides fall quiet
    /// around the same turns, which lifts the correlation well above zero
    /// without any bleed. The clean recordings in the corpus reach 0.3 to 0.55
    /// per window, and the threshold has to survive that.
    func testTurnTakingWithoutBleedStaysBelowTheThreshold() throws {
        let rawA = speechLike(seconds: 120, seed: 24)
        let rawB = speechLike(seconds: 120, seed: 61)
        var app = [Float](repeating: 0, count: rawA.count)
        var mic = [Float](repeating: 0, count: rawB.count)
        for i in rawA.indices {
            // A shared slow turn pattern: whoever holds the floor is loud, the
            // other stays quiet but not silent. Different voices, common rhythm.
            let t = Double(i) / Double(rate)
            let floorIsApp = sin(2 * .pi * 0.05 * t) > 0
            app[i] = rawA[i] * Float(floorIsApp ? 1.0 : 0.15)
            mic[i] = rawB[i] * Float(floorIsApp ? 0.15 : 1.0)
        }
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertFalse(
            result.isAffected,
            "turn taking is not bleed; share was \(result.affectedWindowShare)",
        )
    }
}
