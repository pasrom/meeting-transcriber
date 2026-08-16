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
}
