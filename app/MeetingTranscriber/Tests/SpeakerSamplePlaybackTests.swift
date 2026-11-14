@testable import MeetingTranscriber
import os
import ViewInspector
import XCTest

/// The play button in the naming dialog plays a speaker's sample from their
/// own track, and from the mix when that track cannot give one: the mix is
/// what the button played before the tracks were used.
@MainActor
final class SpeakerSamplePlaybackTests: XCTestCase {
    private typealias NamingData = PipelineQueue.SpeakerNamingData
    private typealias Source = NamingData.SampleSource

    private let sampleRate = 16000
    private let micDelay: TimeInterval = 0.25

    private func namingData(mix: URL, app: URL, mic: URL) -> NamingData {
        var data = NamingData(
            jobID: UUID(), meetingTitle: "Standup",
            mapping: ["M_SPEAKER_1": "M_SPEAKER_1"], speakingTimes: ["M_SPEAKER_1": 4],
            embeddings: ["M_SPEAKER_1": [0.1, 0.2, 0.3]], audioPath: mix,
            segments: [.init(start: 10, end: 14, speaker: "M_SPEAKER_1")],
            participants: [], isDualSource: true,
        )
        data.tracks = .init(app: app, mic: mic, micDelay: micDelay)
        return data
    }

    // MARK: - The button

    func testThePlayButtonAsksForTheSpeakersOwnTrackFirstThenTheMix() async throws {
        let mix = URL(fileURLWithPath: "/rec/standup_16k.wav")
        let app = URL(fileURLWithPath: "/rec/standup_app_16k.wav")
        let mic = URL(fileURLWithPath: "/rec/standup_mic_16k.wav")
        let asked = OSAllocatedUnfairLock<[Source]>(initialState: [])
        let loaded = expectation(description: "the button asked for a sample")
        var sut = SpeakerNamingView(data: namingData(mix: mix, app: app, mic: mic), gracePeriod: 0) { _ in }
        sut.sampleLoader = { sources in
            asked.withLock { $0 = sources }
            loaded.fulfill()
            return nil
        }

        try sut.inspect().find(viewWithAccessibilityIdentifier: A11yID.play("M_SPEAKER_1")).button().tap()
        await fulfillment(of: [loaded], timeout: 5)

        XCTAssertEqual(asked.withLock { $0 }, [
            Source(url: mic, start: 10 - micDelay, end: 14 - micDelay),
            Source(url: mix, start: 10, end: 14),
        ])
    }

    // MARK: - Reading the files

    private struct Recording {
        let mix: URL
        let app: URL
        let mic: URL
    }

    /// Every file holds one constant value, so the sample shows which file it
    /// was read from. Each file is 20 s long unless `micSeconds` says otherwise;
    /// a nil `micSeconds` writes no microphone file.
    private func makeRecording(micSeconds: Int? = 20) throws -> Recording {
        let dir = try makeTempDirectory(prefix: "SpeakerSamplePlayback")
        let recording = Recording(
            mix: dir.appendingPathComponent("standup_16k.wav"),
            app: dir.appendingPathComponent("standup_app_16k.wav"),
            mic: dir.appendingPathComponent("standup_mic_16k.wav"),
        )
        try write(0.3, seconds: 20, to: recording.mix)
        try write(0.1, seconds: 20, to: recording.app)
        if let micSeconds {
            try write(0.2, seconds: micSeconds, to: recording.mic)
        }
        return recording
    }

    private func write(_ value: Float, seconds: Int, to url: URL) throws {
        try AudioMixer.saveWAV(samples: Array(repeating: value, count: sampleRate * seconds), sampleRate: sampleRate, url: url)
    }

    /// The value the sample of `M_SPEAKER_1` holds, or nil when it got none.
    private func playedValue(_ recording: Recording) throws -> Float? {
        let data = namingData(mix: recording.mix, app: recording.app, mic: recording.mic)
        let segment = try XCTUnwrap(data.segments.first)
        guard let wav = SpeakerNamingView.sampleWAVData(from: data.sampleSources(for: segment)) else { return nil }
        let file = try makeTempDirectory(prefix: "SpeakerSampleWAV").appendingPathComponent("sample.wav")
        try wav.write(to: file)
        let samples = try XCTUnwrap(SpeakerNamingView.snippetSamples(audioPath: file, start: 0, end: 4)).samples
        XCTAssertEqual(Double(samples.count), Double(4 * sampleRate), accuracy: 2)
        let first = try XCTUnwrap(samples.first)
        XCTAssertLessThanOrEqual(samples.map { abs($0 - first) }.max() ?? .infinity, 2.0 / 32768, "a sample from two files")
        return first
    }

    func testTheSampleIsReadFromTheSpeakersOwnTrack() throws {
        XCTAssertEqual(try XCTUnwrap(playedValue(makeRecording())), 0.2, accuracy: 0.001)
    }

    func testAMissingTrackPlaysTheMix() throws {
        XCTAssertEqual(try XCTUnwrap(playedValue(makeRecording(micSeconds: nil))), 0.3, accuracy: 0.001)
    }

    func testATrackThatIsNotAudioPlaysTheMix() throws {
        let recording = try makeRecording()
        try Data("not a wav".utf8).write(to: recording.mic)

        XCTAssertEqual(try XCTUnwrap(playedValue(recording)), 0.3, accuracy: 0.001)
    }

    func testATrackThatEndsBeforeTheSpanPlaysTheMix() throws {
        XCTAssertEqual(try XCTUnwrap(playedValue(makeRecording(micSeconds: 5))), 0.3, accuracy: 0.001)
    }
}
