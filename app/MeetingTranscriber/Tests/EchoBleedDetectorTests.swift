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

    /// Speech-like: noise shaped by a slow envelope, so the 10 ms envelope has
    /// structure to correlate. Flat noise correlates on nothing.
    ///
    /// The **envelope** has to vary with the seed, not just the noise beneath
    /// it. A first version modulated every talker identically and only reseeded
    /// the carrier, which made two supposedly independent talkers correlate at
    /// exactly 1.0 — the detector compares envelopes, so identical envelopes are
    /// identical evidence. The tests caught it, which is the point of having the
    /// negative cases.
    private func speechLike(seconds: Double, seed: UInt64) -> [Float] {
        let raw = noise(seconds: seconds, seed: seed)
        let syllableRate = 2.4 + Double(seed % 7) * 0.35 // distinct talkers, 2.4 to 4.5 Hz
        let phase = Double(seed % 11) / 11 * 2 * .pi
        let pauseRate = 0.13 + Double(seed % 5) * 0.06
        var out = [Float](repeating: 0, count: raw.count)
        for i in raw.indices {
            let t = Double(i) / Double(rate)
            let env = max(0, sin(2 * .pi * syllableRate * t + phase))
                * (sin(2 * .pi * pauseRate * t + phase) > -0.3 ? 1 : 0)
            out[i] = raw[i] * Float(env)
        }
        return out
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
}
