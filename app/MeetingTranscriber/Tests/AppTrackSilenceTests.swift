@testable import MeetingTranscriber
import XCTest

/// Pins the evidence half of the echo quarantine: which microphone speakers did
/// their talking while the app track was carrying nothing.
///
/// This is the only thing that can *admit* an embedding from a recording known
/// to be affected, so it is the part where a mistake is expensive and permanent
/// — `SpeakerMatcher` folds a confirmed embedding into a running-mean centroid
/// with no history. Every test here therefore asks "does this wrongly admit",
/// and the two of them that assert admission exist so the filter cannot be
/// satisfied by simply proving nothing.
final class AppTrackSilenceTests: XCTestCase {
    private lazy var tmp: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-track-silence-\(UUID().uuidString)")
    private let rate = 16000
    private let mic = SpeakerKey(track: .mic, id: "SPEAKER_0").encoded

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// An app track of `seconds`, silent everywhere except the given spans.
    private func appTrack(seconds: Double, loud: [(Double, Double)], level: Float = 0.3) throws -> URL {
        var samples = [Float](repeating: 0, count: Int(seconds * Double(rate)))
        for (start, end) in loud {
            for i in Int(start * Double(rate)) ..< min(Int(end * Double(rate)), samples.count) {
                // Alternating sign rather than a constant: a DC offset is not
                // audio, and RMS would read it the same either way, so the
                // fixture would not distinguish a real signal from a bug.
                samples[i] = i.isMultiple(of: 2) ? level : -level
            }
        }
        let url = tmp.appendingPathComponent("track-\(UUID().uuidString).wav")
        try AudioMixer.saveWAV(samples: samples, sampleRate: rate, url: url)
        return url
    }

    private func segment(_ start: Double, _ end: Double, _ speaker: String) -> PipelineQueue.SpeakerNamingData.Segment {
        .init(start: start, end: end, speaker: speaker)
    }

    // MARK: - Admission

    func testSpeakerWhoTalkedOverASilentAppTrackIsProven() throws {
        let track = try appTrack(seconds: 30, loud: [])
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(2, 6, mic), segment(12, 18, mic)], appTrackURL: track,
        )
        XCTAssertEqual(proven, [mic], "nothing was playing, so nothing can have bled through")
    }

    /// The far end talking for a fifth of this speaker's time is exactly the
    /// share boundary, and the rule admits at the boundary. Pinned because a
    /// stricter or looser comparison here silently changes who gets learned.
    func testExactlyTheRequiredShareIsEnoughToBeProven() throws {
        // 10 s of talking, 2 s of it over far-end audio: 80 % silent.
        let track = try appTrack(seconds: 30, loud: [(0, 2)])
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(0, 2, mic), segment(2, 10, mic)], appTrackURL: track,
        )
        XCTAssertEqual(proven, [mic])
    }

    // MARK: - Refusal

    func testSpeakerWhoTalkedOverFarEndAudioIsNotProven() throws {
        let track = try appTrack(seconds: 30, loud: [(0, 30)])
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(2, 6, mic), segment(12, 18, mic)], appTrackURL: track,
        )
        XCTAssertTrue(proven.isEmpty, "the far end was audible throughout; this is exactly the bleed case")
    }

    func testMajorityButNotEnoughSilenceIsNotProven() throws {
        // 10 s of talking, 4 s of it over far-end audio: 60 % silent.
        let track = try appTrack(seconds: 30, loud: [(0, 4)])
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(0, 4, mic), segment(4, 10, mic)], appTrackURL: track,
        )
        XCTAssertTrue(proven.isEmpty, "a majority is not the bar; the bar is nearly all of it")
    }

    /// Quiet is not silent. The threshold is near-digital silence on purpose:
    /// a far end at conversational level a room away still bleeds, and reading
    /// "quiet" as "nothing was playing" would admit precisely those.
    func testQuietButAudibleFarEndIsNotSilence() throws {
        // -40 dBFS: inaudible in a noisy room, twenty decibels above the floor.
        let track = try appTrack(seconds: 30, loud: [(0, 30)], level: 0.01)
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(2, 12, mic)], appTrackURL: track,
        )
        XCTAssertTrue(proven.isEmpty)
    }

    func testAppTrackSpeakersAreNotCandidates() throws {
        let remote = SpeakerKey(track: .app, id: "SPEAKER_0").encoded
        let track = try appTrack(seconds: 30, loud: [])
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(2, 12, remote)], appTrackURL: track,
        )
        XCTAssertTrue(
            proven.isEmpty,
            "the app track is admissible anyway; naming it here would be evidence about the wrong thing",
        )
    }

    // MARK: - No evidence is a refusal, never an admission

    func testMissingAppTrackYieldsNoEvidence() {
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(2, 12, mic)],
            appTrackURL: tmp.appendingPathComponent("never-written.wav"),
        )
        XCTAssertTrue(proven.isEmpty, "an unreadable sidecar proves nothing, so the whole track stays held")
    }

    /// The stretch a speaker talked over has to be *read* to be called silent.
    /// A segment past the end of the app track cannot be, and the fallback has
    /// to be "not silent" — the direction that holds an embedding back. Reading
    /// an unreadable stretch as silence would admit on the strength of a short
    /// file, which is how a truncated or still-flushing sidecar would poison
    /// the database.
    func testSegmentBeyondTheEndOfTheAppTrackIsNotTakenAsSilence() throws {
        let track = try appTrack(seconds: 5, loud: [])
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(20, 30, mic)], appTrackURL: track,
        )
        XCTAssertTrue(proven.isEmpty)
    }

    func testZeroLengthSegmentsProveNothingAndDoNotDivideByZero() throws {
        let track = try appTrack(seconds: 30, loud: [])
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(4, 4, mic)], appTrackURL: track,
        )
        XCTAssertTrue(proven.isEmpty)
    }

    func testNoSegmentsYieldNoEvidence() throws {
        let track = try appTrack(seconds: 30, loud: [])
        XCTAssertTrue(AppTrackSilence.micSpeakersProvenClean(segments: [], appTrackURL: track).isEmpty)
    }

    // MARK: - One speaker's evidence is only about that speaker

    func testEvidenceIsPerSpeaker() throws {
        let second = SpeakerKey(track: .mic, id: "SPEAKER_1").encoded
        let track = try appTrack(seconds: 40, loud: [(20, 40)])
        let proven = AppTrackSilence.micSpeakersProvenClean(
            segments: [segment(2, 12, mic), segment(24, 34, second)], appTrackURL: track,
        )
        XCTAssertEqual(
            proven, [mic],
            "the one who spoke into a quiet room is proven; the one who spoke over the far end is not",
        )
    }
}
