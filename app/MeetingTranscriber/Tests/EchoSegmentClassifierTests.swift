@testable import MeetingTranscriber
import XCTest

/// Pins the decision behind transcript-level dedup: for one microphone segment,
/// is its energy explained by the app track (the loudspeaker coming back), or
/// does it carry something the app track cannot account for (the person at the
/// machine actually speaking)?
///
/// The whole design rests on that question being answered from the **audio**.
/// Text similarity cannot answer it: a far end replaying what you just said and
/// a loudspeaker bleeding into your microphone produce the same two lines. Only
/// the acoustics separate them, and getting this wrong deletes the user's own
/// words, which is the failure that killed two earlier approaches.
final class EchoSegmentClassifierTests: XCTestCase {
    private let rate = EchoTestAudio.rate

    private func seg(_ start: Double, _ end: Double) -> TimestampedSegment {
        TimestampedSegment(start: start, end: end, text: "x")
    }

    /// Far end talking, microphone carrying nothing but its loudspeaker copy.
    func testPureLoudspeakerCopyIsEchoOnly() {
        let app = EchoTestAudio.speechLike(seconds: 30, seed: 1)
        let mic = EchoTestAudio.bleed(app, delayMs: 15, gain: 0.5)

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(5, 25)],
        )
        XCTAssertEqual(out, [.echoOnly])
    }

    /// The person speaks while the far end is silent. Nothing was playing, so
    /// nothing can have bled: this must survive untouched.
    func testSpeechOverASilentAppTrackIsOwnVoice() {
        let app = [Float](repeating: 0, count: 30 * rate)
        let mic = EchoTestAudio.speechLike(seconds: 30, seed: 2)

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(5, 25)],
        )
        XCTAssertEqual(out, [.ownVoice])
    }

    /// The case that matters most, and the one a text comparison gets wrong:
    /// one segment holding the loudspeaker copy **and** the local speaker.
    /// Deleting it would take the user's own sentence with it.
    ///
    /// Asserted as "audible and not removable" rather than as one of the two
    /// keep-verdicts. Where a given mixture lands between `mixed` and `ownVoice`
    /// depends on how much of the segment the far end happens to fill, and no
    /// caller distinguishes them; pinning a particular one here would pin an
    /// arbitrary threshold rather than a behaviour. `undecided` is excluded on
    /// purpose, so this still fails against a classifier that has stopped
    /// deciding anything.
    func testSegmentCarryingLocalSpeechIsNeverRemovable() {
        let app = EchoTestAudio.speechLike(seconds: 30, seed: 3)
        let echo = EchoTestAudio.bleed(app, delayMs: 15, gain: 0.5)
        let own = EchoTestAudio.speechLike(seconds: 30, seed: 44)
        let mic = zip(echo, own).map { $0 + $1 }

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(5, 25)],
        )
        XCTAssertTrue(
            out == [.mixed] || out == [.ownVoice],
            "a segment with local speech in it must be kept, got \(out)",
        )
    }

    /// Double talk with an asymmetry: the far end is loud, the person at the
    /// machine is soft and only ever speaks while the far end does — the
    /// interjecting listener. A gain estimate that averages over the whole
    /// recording absorbs the soft voice into the loudspeaker path: the fitted
    /// gain comes out a little high, the prediction "explains" the quiet
    /// voice, and the segment reads as a copy. That deletes the words of
    /// exactly the participant least able to shout over the far end, so this
    /// must never be `.echoOnly` however soft the local side is.
    ///
    /// The masking is the point of the fixture: a local speaker who also
    /// talks into the far end's pauses leaves unexplainable energy there and
    /// is safe under any gain estimate. Only pure double talk exposes the
    /// bias.
    func testSoftLocalSpeakerOverTheFarEndIsNeverRemovable() {
        let app = EchoTestAudio.speechLike(seconds: 30, seed: 12)
        let echo = EchoTestAudio.bleed(app, delayMs: 15, gain: 0.5)
        var own = EchoTestAudio.speechLike(seconds: 30, seed: 77)
        for i in own.indices where echo[i] == 0 {
            own[i] = 0
        }
        let mic = zip(echo, own).map { $0 + 0.3 * $1 }

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(5, 25)],
        )
        XCTAssertNotEqual(out, [.echoOnly], "a soft local speaker is still a speaker, not part of the room path")
    }

    /// Per segment, not per recording: one call has to tell the two apart in the
    /// same pair, which is what a real meeting looks like.
    func testEchoAndOwnVoiceAreSeparatedWithinOneRecording() {
        var app = EchoTestAudio.speechLike(seconds: 60, seed: 4)
        // Far end silent for the middle twenty seconds.
        for i in (20 * rate) ..< (40 * rate) {
            app[i] = 0
        }
        var mic = EchoTestAudio.bleed(app, delayMs: 15, gain: 0.5)
        let own = EchoTestAudio.speechLike(seconds: 60, seed: 55)
        for i in (22 * rate) ..< (38 * rate) {
            mic[i] = own[i]
        }

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(2, 18), seg(23, 37), seg(42, 58)],
        )
        XCTAssertEqual(out, [.echoOnly, .ownVoice, .echoOnly])
    }

    // MARK: - Refusing to answer

    func testSilentSegmentIsUndecided() {
        let app = EchoTestAudio.speechLike(seconds: 30, seed: 5)
        let mic = [Float](repeating: 0, count: 30 * rate)

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(5, 25)],
        )
        XCTAssertEqual(out, [.undecided], "there is nothing in this segment to keep or drop")
    }

    /// With no far-end activity anywhere the acoustic path cannot be estimated.
    /// Whatever the answer is, it may not be "removable": on a recording where
    /// nothing was played, nothing can be a loudspeaker copy.
    func testNothingIsRemovableWhenTheAppTrackNeverPlays() {
        let app = [Float](repeating: 0, count: 30 * rate)
        let mic = EchoTestAudio.speechLike(seconds: 30, seed: 6)

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(2, 12), seg(14, 28)],
        )
        XCTAssertFalse(out.contains(.echoOnly))
    }

    func testSegmentBeyondTheRecordingIsUndecided() {
        let app = EchoTestAudio.speechLike(seconds: 10, seed: 7)
        let mic = EchoTestAudio.bleed(app, delayMs: 15, gain: 0.5)

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(30, 40)],
        )
        XCTAssertEqual(out, [.undecided])
    }

    func testNoSegmentsYieldsNoVerdicts() {
        let app = EchoTestAudio.speechLike(seconds: 10, seed: 8)
        XCTAssertTrue(EchoSegmentClassifier.classify(
            app: app, mic: app, sampleRate: rate, micDelay: 0, micSegments: [],
        ).isEmpty)
    }

    // MARK: - The offset, and its sign

    /// Same trap as the detector: a microphone that started late puts its copy
    /// of the app audio at a different file index, and the classifier has to be
    /// told. Without the offset the copy no longer predicts the microphone, the
    /// residual stays high, and the segment reads as the user's own speech.
    ///
    /// That failure is safe (nothing is deleted) and therefore invisible, which
    /// is exactly why it needs a test: silently keeping every duplicate looks
    /// identical to having no bleed at all.
    ///
    /// The fixture drops the opening half second from the microphone, which is
    /// what a late start produces. Adding delay instead models a 170 m sound
    /// path and passes under either sign.
    func testLateStartingMicNeedsItsOffsetToBeRecognised() {
        let app = EchoTestAudio.speechLike(seconds: 40, seed: 9)
        let lateStart = Int(0.5 * Double(rate))
        let mic = Array(EchoTestAudio.bleed(app, delayMs: 15, gain: 0.5).dropFirst(lateStart))

        let blind = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(5, 30)],
        )
        XCTAssertNotEqual(blind, [.echoOnly], "500 ms out of alignment, the copy no longer explains the segment")

        let informed = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0.5,
            micSegments: [seg(5, 30)],
        )
        XCTAssertEqual(informed, [.echoOnly], "told the offset, the same segment is recognised as the copy it is")
    }

    /// A Bluetooth loudspeaker adds 100–200 ms of path delay that `micDelay`
    /// knows nothing about — it only says when the files started. The detector
    /// already measured, per window, at what lag the tracks actually match, so
    /// the classifier has to take its alignment from that measurement. Blind,
    /// the copy no longer predicts the microphone and every duplicate is kept;
    /// informed, the same segment is recognised as the copy it is.
    func testBluetoothPathDelayComesFromTheDetectorsMeasurement() throws {
        let app = EchoTestAudio.speechLike(seconds: 40, seed: 23)
        let mic = EchoTestAudio.bleed(app, delayMs: 150, gain: 0.5)
        let result = try XCTUnwrap(
            EchoBleedDetector.analyse(app: app, mic: mic, sampleRate: rate, micDelay: 0),
            "the detector has to produce the measurement this test threads through",
        )
        XCTAssertTrue(result.isAffected, "the detector's lag search covers the Bluetooth range")

        let blind = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(5, 35)],
        )
        XCTAssertNotEqual(blind, [.echoOnly], "150 ms out of alignment, the copy no longer explains the segment")

        let informed = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(5, 35)],
            windowScores: result.windowScores,
        )
        XCTAssertEqual(informed, [.echoOnly], "given the measured lag, the same segment is the copy it is")
    }

    /// Attenuation varies with the room, so the decision may not be tuned to one
    /// gain. A quiet loudspeaker is still a loudspeaker.
    func testQuietLoudspeakerIsStillRecognised() {
        let app = EchoTestAudio.speechLike(seconds: 30, seed: 10)
        let mic = EchoTestAudio.bleed(app, delayMs: 15, gain: 0.15)

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(5, 25)],
        )
        XCTAssertEqual(out, [.echoOnly])
    }

    /// Guards, not decoration: both arms are reachable from the pipeline. A
    /// zero rate comes from an unreadable header, and an empty envelope from a
    /// track shorter than one 10 ms frame. Either way the answer has to be "no
    /// verdict" rather than a division by zero or a confident nothing.
    func testZeroSampleRateDecidesNothing() {
        let out = EchoSegmentClassifier.classify(
            app: [0.1, 0.2], mic: [0.1, 0.2], sampleRate: 0, micDelay: 0,
            micSegments: [seg(0, 1)],
        )
        XCTAssertEqual(out, [.undecided])
    }

    func testTrackShorterThanOneFrameDecidesNothing() {
        let tiny = [Float](repeating: 0.5, count: 10) // 0.6 ms at 16 kHz
        let out = EchoSegmentClassifier.classify(
            app: tiny, mic: tiny, sampleRate: rate, micDelay: 0,
            micSegments: [seg(0, 1)],
        )
        XCTAssertEqual(out, [.undecided])
    }

    /// A whole recording arriving as ONE segment is not hypothetical: when
    /// Parakeet gets no per-token timings it emits exactly that, a single
    /// segment spanning the full duration. Pooled over minutes the verdict says
    /// nothing about any moment in it, and calling it a copy would delete
    /// everything the local person said for the whole meeting.
    ///
    /// The recording here is pure bleed, so the residual really is near zero.
    /// The point is that the answer must still not be "removable": below some
    /// length the pooled number stops being a statement about a segment.
    func testASegmentSpanningTheWholeRecordingIsNeverRemovable() {
        let app = EchoTestAudio.speechLike(seconds: 120, seed: 31)
        let mic = EchoTestAudio.bleed(app, delayMs: 15, gain: 0.5)

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(0, 120)],
        )
        XCTAssertNotEqual(out, [.echoOnly], "a two-minute segment pools away any local speech inside it")
    }

    /// The guard must not swallow ordinary segments. Engines emit seconds, not
    /// minutes, and those still have to be removable or the feature does
    /// nothing.
    func testOrdinarySegmentLengthsAreStillRemovable() {
        let app = EchoTestAudio.speechLike(seconds: 120, seed: 32)
        let mic = EchoTestAudio.bleed(app, delayMs: 15, gain: 0.5)

        let out = EchoSegmentClassifier.classify(
            app: app, mic: mic, sampleRate: rate, micDelay: 0,
            micSegments: [seg(10, 18), seg(40, 65)],
        )
        XCTAssertEqual(out, [.echoOnly, .echoOnly])
    }
}
