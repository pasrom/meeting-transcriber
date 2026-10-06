@testable import MeetingTranscriber
import XCTest

/// A speaker's sample in the naming dialog plays from their own track, not
/// from the mix. The mix carries both sides at once and lowers the
/// microphone while the far end is loud, so a local speaker's sample from it
/// was quiet and had the other side over it.
final class SpeakerSampleTrackTests: XCTestCase {
    private typealias NamingData = PipelineQueue.SpeakerNamingData

    private let mix = URL(fileURLWithPath: "/rec/standup_16k.wav")
    private let app = URL(fileURLWithPath: "/rec/standup_app_16k.wav")
    private let mic = URL(fileURLWithPath: "/rec/standup_mic_16k.wav")

    private func data(tracks: NamingData.TrackAudio?, audioPath: URL? = nil) -> NamingData {
        var data = NamingData(
            jobID: UUID(), meetingTitle: "Standup", mapping: [:], speakingTimes: [:], embeddings: [:],
            audioPath: audioPath ?? mix, segments: [], participants: [], isDualSource: tracks != nil,
        )
        data.tracks = tracks
        return data
    }

    private func segment(_ speaker: String) -> NamingData.Segment {
        .init(start: 10, end: 14, speaker: speaker)
    }

    private let allExist: (URL) -> Bool = { _ in true }

    func testRemoteSpeakerPlaysFromTheAppTrackAtTheSameTime() throws {
        let tracks = NamingData.TrackAudio(app: app, mic: mic, micDelay: 0.25)
        let source = try XCTUnwrap(data(tracks: tracks).sampleSource(for: segment("R_SPEAKER_0"), fileExists: allExist))
        XCTAssertEqual(source.url, app)
        XCTAssertEqual(source.start, 10)
        XCTAssertEqual(source.end, 14)
    }

    /// The pipeline shifts the microphone's segments by `+micDelay` onto the
    /// app timeline, so the microphone file holds the same speech `micDelay`
    /// earlier.
    func testLocalSpeakerPlaysFromTheMicTrackShiftedBackByTheMicDelay() throws {
        let tracks = NamingData.TrackAudio(app: app, mic: mic, micDelay: 0.25)
        let source = try XCTUnwrap(data(tracks: tracks).sampleSource(for: segment("M_SPEAKER_1"), fileExists: allExist))
        XCTAssertEqual(source.url, mic)
        XCTAssertEqual(source.start, 9.75, accuracy: 1e-9)
        XCTAssertEqual(source.end, 13.75, accuracy: 1e-9)

        let negative = NamingData.TrackAudio(app: app, mic: mic, micDelay: -0.4)
        let shifted = try XCTUnwrap(data(tracks: negative).sampleSource(for: segment("M_SPEAKER_1"), fileExists: allExist))
        XCTAssertEqual(shifted.start, 10.4, accuracy: 1e-9)
    }

    /// One track failed and the other was diarized alone: the labels carry no
    /// prefix, so which track they came from is unknown.
    func testUnprefixedLabelPlaysFromTheMix() throws {
        let tracks = NamingData.TrackAudio(app: app, mic: mic, micDelay: 0.25)
        let source = try XCTUnwrap(data(tracks: tracks).sampleSource(for: segment("SPEAKER_0"), fileExists: allExist))
        XCTAssertEqual(source.url, mix)
        XCTAssertEqual(source.start, 10)
    }

    func testWithoutTracksEverySpeakerPlaysFromTheMix() throws {
        let source = try XCTUnwrap(data(tracks: nil).sampleSource(for: segment("M_SPEAKER_1"), fileExists: allExist))
        XCTAssertEqual(source.url, mix)
        XCTAssertEqual(source.start, 10)
    }

    func testAMissingTrackFileFallsBackToTheMix() throws {
        let tracks = NamingData.TrackAudio(app: app, mic: mic, micDelay: 0.25)
        let micPath = mic
        let source = try XCTUnwrap(data(tracks: tracks).sampleSource(for: segment("M_SPEAKER_1")) { $0 != micPath })
        XCTAssertEqual(source.url, mix)
        XCTAssertEqual(source.start, 10)
    }

    // MARK: - Stored naming data

    /// Naming data written before the tracks were recorded must still load:
    /// an open naming survives an update and a restart.
    func testNamingDataWithoutTracksStillDecodes() throws {
        let legacy = """
        {"jobID":"\(UUID().uuidString)","meetingTitle":"Standup","mapping":{},"speakingTimes":{},\
        "embeddings":{},"audioPath":"file:///rec/standup_16k.wav","segments":[],"participants":[],\
        "isDualSource":true}
        """
        let decoded = try JSONDecoder().decode(NamingData.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.tracks)
        XCTAssertTrue(decoded.isDualSource)
    }

    func testTracksSurviveARoundTrip() throws {
        let tracks = NamingData.TrackAudio(app: app, mic: mic, micDelay: 0.25)
        let encoded = try JSONEncoder().encode(data(tracks: tracks))
        XCTAssertEqual(try JSONDecoder().decode(NamingData.self, from: encoded).tracks, tracks)
    }
}
