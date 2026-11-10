@testable import MeetingTranscriber
import XCTest

/// The naming dialog's play button cuts one segment out of the meeting's
/// 16 kHz mix. It must read that segment alone, not the whole meeting, and it
/// must leave no copy of it behind: the snippet is real meeting audio.
final class SpeakerSnippetAudioTests: XCTestCase {
    private let sampleRate = 16000

    /// Three seconds whose every frame has its own value, so a read from the
    /// wrong position cannot match by accident.
    private func writeRamp(to url: URL) throws -> [Float] {
        let count = sampleRate * 3
        let samples = (0 ..< count).map { Float($0) / Float(count) * 0.9 }
        try AudioMixer.saveWAV(samples: samples, sampleRate: sampleRate, url: url)
        return samples
    }

    private func makeMix() throws -> (url: URL, ramp: [Float]) {
        let mix = try makeTempDirectory(prefix: "SnippetFixture").appendingPathComponent("meeting_16k.wav")
        return try (mix, writeRamp(to: mix))
    }

    func testTheSnippetHoldsExactlyTheRequestedFrames() throws {
        let (mix, ramp) = try makeMix()

        let snippet = try XCTUnwrap(SpeakerNamingView.snippetSamples(audioPath: mix, start: 1.25, end: 1.75))

        XCTAssertEqual(snippet.sampleRate, sampleRate)
        let expected = Array(ramp[20000 ..< 28000])
        XCTAssertEqual(snippet.samples.count, expected.count)
        let worst = zip(snippet.samples, expected).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThanOrEqual(worst, 2.0 / 32768, "read from the wrong position")
    }

    func testNoCopyOfTheSnippetIsLeftOnDisk() throws {
        let (mix, _) = try makeMix()
        let scratch = try makeTempDirectory(prefix: "SnippetScratch")

        let wav = try XCTUnwrap(SpeakerNamingView.snippetWAVData(
            audioPath: mix, start: 0.5, end: 1.0, scratchDir: scratch,
        ))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        XCTAssertGreaterThan(wav.count, 44, "a WAV header with no samples")
    }

    func testASegmentPastTheEndOfTheAudioGivesNothing() throws {
        let (mix, _) = try makeMix()

        XCTAssertNil(try SpeakerNamingView.snippetSamples(audioPath: mix, start: 5, end: 6))
    }
}
