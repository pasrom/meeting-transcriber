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

    private func speechLike(seconds: Double, seed: UInt64) -> [Float] {
        EchoTestAudio.speechLike(seconds: seconds, seed: seed)
    }

    private func bleed(_ source: [Float], delayMs: Double, gain: Float) -> [Float] {
        EchoTestAudio.bleed(source, delayMs: delayMs, gain: gain)
    }

    // MARK: - The two populations

    func testFullBleedIsDetected() throws {
        let app = speechLike(seconds: 60, seed: 1)
        let mic = bleed(app, delayMs: 15, gain: 0.5)

        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertGreaterThan(result.affectedWindowShare, 0.9, "a pure room copy must light up nearly every window")
        XCTAssertTrue(result.isAffected)
        XCTAssertEqual(result.routes, [.share, .farEndShare, .lockedLag], "a full copy clears every rule")
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

    // MARK: - Bleed the plain share misses

    /// A call where the far end speaks in only a few windows and bleeds in
    /// every one of them, while the rest is an idle line and a quiet room. A
    /// window with nothing coming out of the loudspeaker cannot carry bleed,
    /// so counting it in the denominator dilutes the share below the
    /// threshold however hard the far end bleeds when it does talk.
    func testBleedInTheFewWindowsTheFarEndTalksIsDetected() throws {
        let seconds = 300.0
        var farEnd = [Float](repeating: 0, count: Int(seconds) * rate)
        for window in [3, 9, 15, 21] {
            let start = window * 10 * rate
            for (i, sample) in speechLike(seconds: 10, seed: UInt64(window)).enumerated() {
                farEnd[start + i] = sample
            }
        }
        // The idle line's own noise stays on the app track only: crossing the
        // room at half gain puts it under the room's noise, so the windows
        // the far end spoke in are the only ones the two tracks share.
        let line = EchoTestAudio.noise(seconds: seconds, amplitude: 0.002, seed: 31)
        let room = EchoTestAudio.noise(seconds: seconds, amplitude: 0.002, seed: 32)
        let app = EchoTestAudio.mix(farEnd, line)
        let mic = EchoTestAudio.mix(bleed(farEnd, delayMs: 15, gain: 0.5), room)

        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertEqual(result.windowsScored, 30, "the idle windows still score, they are not digital zero")
        XCTAssertEqual(result.windowsAffected, 4, "exactly the windows the far end spoke in")
        XCTAssertTrue(result.isAffected, "share over all windows was \(result.affectedWindowShare)")
        XCTAssertEqual(result.routes, [.farEndShare], "only the far-end share sees it")
    }

    /// Bleed in every window, but under a louder local talker, so only the
    /// two windows the local side is quiet in clear the per-window threshold.
    /// What still gives it away is the lag: bleed travels one fixed path, so
    /// the masked windows keep peaking where the clear ones did.
    func testMaskedBleedAtAStableLagIsDetected() throws {
        let (app, mic) = maskedBleed(delayMs: 40)
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertEqual(result.windowsScored, 20)
        XCTAssertEqual(result.windowsAffected, 2, "only the unmasked windows are hot")
        let atPath = result.windowScores.count { abs($0.lagSeconds - 0.04) <= 0.0105 }
        XCTAssertGreaterThan(atPath, 10, "most windows still peak on the bleed path")
        XCTAssertTrue(result.isAffected)
        XCTAssertEqual(result.routes, [.lockedLag], "neither share rule sees it")
    }

    /// The same masked bleed with its path at the very edge of the search. A
    /// clean call piles its peaks up at an edge too, wherever the correlation
    /// is still rising when the search stops, so a lag mode there is not
    /// evidence of one path.
    func testALagModeAtTheSearchEdgeIsNotEvidence() throws {
        let (app, mic) = maskedBleed(delayMs: 300)
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertEqual(result.windowsAffected, 2)
        let atEdge = result.windowScores.count { abs($0.lagSeconds - 0.3) <= 0.0105 }
        XCTAssertGreaterThan(atEdge, 10, "the fixture does lock, just at the edge")
        XCTAssertFalse(result.isAffected)
    }

    /// Two windows that happen to correlate on an otherwise clean pair, each at
    /// its own lag. Two hot windows clear the count floor, but nothing locks.
    func testTwoCoincidentalHotWindowsAtScatteredLagsStayClean() throws {
        let app = speechLike(seconds: 300, seed: 41)
        var mic = speechLike(seconds: 300, seed: 42)
        // A negative delay is a copy that sits early in the mic file.
        for (window, delayMs) in [(5, -120.0), (20, 180.0)] {
            let start = window * 10 * rate
            let shift = Int(delayMs / 1000 * Double(rate))
            for i in start ..< (start + 10 * rate) {
                mic[i] = app[i - shift] * 0.5
            }
        }
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertEqual(result.windowsAffected, 2, "the two planted windows are hot")
        let hotLags = Set(result.windowScores.filter(\.isHot).map { Int(($0.lagSeconds * 1000).rounded()) })
        XCTAssertEqual(hotLags, [-120, 180])
        XCTAssertFalse(result.isAffected)
    }

    /// The far end talks throughout and bleeds at `delayMs` in every window;
    /// a louder, independent local talker covers all but the first two.
    private func maskedBleed(delayMs: Double) -> (app: [Float], mic: [Float]) {
        let app = speechLike(seconds: 200, seed: 43)
        let local = speechLike(seconds: 200, seed: 44)
        var mic = bleed(app, delayMs: delayMs, gain: 0.5)
        for i in (20 * rate) ..< mic.count {
            mic[i] += local[i]
        }
        return (app, mic)
    }

    // MARK: - The logged series

    /// A window with a flat envelope scores nothing, but it still took ten
    /// seconds. The logged series keeps a placeholder at its index, so the
    /// n-th entry is the n-th ten seconds of the recording; dropping it would
    /// shift every later window and put a field report's evidence at the
    /// wrong time.
    func testTheLoggedSeriesKeepsAnUnscoredWindowInPlace() throws {
        var app = speechLike(seconds: 40, seed: 51)
        for i in (10 * rate) ..< (20 * rate) {
            app[i] = 0
        }
        let mic = bleed(app, delayMs: 20, gain: 0.5)
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertEqual(result.windowsScored, 3)

        let entries = PipelineQueue.windowDetail(result.windows).split(separator: " ")
        XCTAssertEqual(entries.count, 4, "one entry per ten seconds")
        XCTAssertEqual(entries[1], "-")
        XCTAssertTrue(entries[2].hasSuffix("@20"), "the window after the gap stays at its own index: \(entries)")
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
        let mic = bleed(app, delayMs: 150, gain: 0.5)
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertTrue(result.isAffected)
    }

    /// An external or Bluetooth output adds its own latency to the room path,
    /// so the microphone copy can arrive well over 200 ms after the point the
    /// recorder aligned the tracks to. A search that stops at 200 ms finds
    /// nothing there, and the miss is silent. The fixture sits close to the
    /// upper edge rather than just past 200 ms: its envelope is smoother than
    /// speech, so a copy only 50 ms past the old edge still correlated there
    /// and the test would not have failed without the wider search.
    func testBleedThroughASlowOutputDeviceIsDetected() throws {
        let app = speechLike(seconds: 60, seed: 25)
        let mic = bleed(app, delayMs: 290, gain: 0.5)
        let result = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertTrue(result.isAffected, "share was \(result.affectedWindowShare)")
        let lags = Set(result.windowScores.map { Int(($0.lagSeconds * 1000).rounded()) })
        XCTAssertEqual(lags, [290], "every window peaks on the path the copy took")
    }

    /// The failure this guards is invisible: a mic that starts late puts real
    /// bleed outside the search window and the recording reads as clean. The
    /// recorder knows the offset, so passing it must restore detection.
    /// A microphone that started half a second late — a Bluetooth device
    /// spinning up — which is the case `micDelay` exists for.
    ///
    /// The fixture has to model a *late start*, not a long acoustic path. Those
    /// are opposite index relationships and only one of them is physical: the
    /// recorder's convention (`AudioMixer.mix` prepends zeros to a late mic,
    /// `mergeDualSourceSegments` shifts mic times by `+micDelay`) means the mic
    /// file is *missing* its first `micDelay` seconds, so its copy of the app
    /// audio sits EARLIER in file-index terms. A fixture built by adding delay
    /// instead puts the peak on the opposite side, where an inverted search
    /// centre still finds it and the test certifies the wrong sign.
    func testMicThatStartedLateNeedsMicDelayToBeFound() throws {
        let app = speechLike(seconds: 60, seed: 22)
        // Everything the mic would have captured, minus the half second it was
        // not yet recording.
        let lateStart = Int(0.5 * Double(rate))
        let mic = Array(bleed(app, delayMs: 15, gain: 0.5).dropFirst(lateStart))

        let blind = try XCTUnwrap(EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate))
        XCTAssertFalse(blind.isAffected, "500 ms early is outside the 200 ms the search reaches early, so nothing is found")

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
