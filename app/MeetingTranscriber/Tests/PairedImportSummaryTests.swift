@testable import MeetingTranscriber
import XCTest

final class PairedImportSummaryTests: XCTestCase {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    func testEmptySelectionShowsBlank() {
        XCTAssertEqual(PairedImportSummary.text(forSelectedURLs: []), " ")
    }

    func testSinglePairWithMixAnchorIs1Transcript() {
        let text = PairedImportSummary.text(forSelectedURLs: [
            url("meeting_app.wav"),
            url("meeting_mic.wav"),
            url("meeting_mix.wav"),
        ])
        XCTAssertEqual(text, "1 paired recording → 1 transcript")
    }

    func testTwoPairsArePluralized() {
        let text = PairedImportSummary.text(forSelectedURLs: [
            url("a_app.wav"), url("a_mic.wav"), url("a_mix.wav"),
            url("b_app.wav"), url("b_mic.wav"), url("b_mix.wav"),
        ])
        XCTAssertEqual(text, "2 paired recordings → 2 transcripts")
    }

    func testMixedPairAndSingleton() {
        let text = PairedImportSummary.text(forSelectedURLs: [
            url("meeting_app.wav"),
            url("meeting_mic.wav"),
            url("meeting_mix.wav"),
            url("podcast.mp3"),
        ])
        XCTAssertEqual(text, "1 paired recording + 1 single file → 2 transcripts")
    }

    func testAppPlusMicWithoutMixIsOnePairedRecording() {
        // app+mic without mix is paired — synthesizer creates the mix on enqueue.
        let text = PairedImportSummary.text(forSelectedURLs: [
            url("meeting_app.wav"),
            url("meeting_mic.wav"),
        ])
        XCTAssertEqual(text, "1 paired recording → 1 transcript")
    }

    func testOnlySingletons() {
        let text = PairedImportSummary.text(forSelectedURLs: [
            url("one.mp3"),
            url("two.m4a"),
        ])
        XCTAssertEqual(text, "2 single files → 2 transcripts")
    }

    func testLoneAppFallsBackAndIsCountedAsSingle() {
        let text = PairedImportSummary.text(forSelectedURLs: [
            url("orphan_app.wav"),
        ])
        XCTAssertEqual(text, "1 single file → 1 transcript")
    }
}
