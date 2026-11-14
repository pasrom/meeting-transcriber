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

    private typealias Source = NamingData.SampleSource

    func testRemoteSpeakerPlaysFromTheAppTrackAtTheSameTimeThenTheMix() {
        let tracks = NamingData.TrackAudio(app: app, mic: mic, micDelay: 0.25)
        XCTAssertEqual(
            data(tracks: tracks).sampleSources(for: segment("R_SPEAKER_0")),
            [Source(url: app, start: 10, end: 14), Source(url: mix, start: 10, end: 14)],
        )
    }

    /// The pipeline moves the microphone's diarization onto the app timeline
    /// with `DiarizationProcess.shiftSegments(_:by: micDelay)`, so a
    /// microphone sample is cut where the diarizer found the speech in the
    /// microphone file. The mix, the fallback, keeps the shifted time.
    func testLocalSpeakerPlaysFromTheMicTrackWhereTheDiarizerFoundThem() throws {
        let raw = DiarizationResult(
            segments: [.init(start: 9.75, end: 13.75, speaker: "SPEAKER_1")],
            speakingTimes: [:], autoNames: [:], embeddings: nil,
        )
        for micDelay in [0.25, -0.4, 100] {
            let shifted = try XCTUnwrap(DiarizationProcess.shiftSegments(raw, by: micDelay).segments.first)
            let tracks = NamingData.TrackAudio(app: app, mic: mic, micDelay: micDelay)
            let sources = data(tracks: tracks).sampleSources(
                for: .init(start: shifted.start, end: shifted.end, speaker: "M_SPEAKER_1"),
            )

            XCTAssertEqual(sources.count, 2, "micDelay \(micDelay)")
            XCTAssertEqual(sources.first?.url, mic, "micDelay \(micDelay)")
            XCTAssertEqual(try XCTUnwrap(sources.first).start, 9.75, accuracy: 1e-9, "micDelay \(micDelay)")
            XCTAssertEqual(try XCTUnwrap(sources.first).end, 13.75, accuracy: 1e-9, "micDelay \(micDelay)")
            XCTAssertEqual(sources.last, Source(url: mix, start: shifted.start, end: shifted.end))
        }
    }

    /// One track failed and the other was diarized alone: the labels carry no
    /// prefix, so which track they came from is unknown.
    func testUnprefixedLabelPlaysFromTheMix() {
        let tracks = NamingData.TrackAudio(app: app, mic: mic, micDelay: 0.25)
        XCTAssertEqual(data(tracks: tracks).sampleSources(for: segment("SPEAKER_0")), [Source(url: mix, start: 10, end: 14)])
    }

    func testWithoutTracksEverySpeakerPlaysFromTheMix() {
        XCTAssertEqual(data(tracks: nil).sampleSources(for: segment("M_SPEAKER_1")), [Source(url: mix, start: 10, end: 14)])
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
