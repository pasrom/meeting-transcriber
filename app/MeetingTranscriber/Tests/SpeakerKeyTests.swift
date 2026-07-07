import Foundation
@testable import MeetingTranscriber
import XCTest

final class SpeakerKeyTests: XCTestCase {
    // MARK: - Round-trip

    func testRoundTripApp() {
        let key = SpeakerKey(track: .app, id: "SPEAKER_0")
        XCTAssertEqual(key.encoded, "R_SPEAKER_0")
        XCTAssertEqual(SpeakerKey(encoded: key.encoded), key)
    }

    func testRoundTripMic() {
        let key = SpeakerKey(track: .mic, id: "SPEAKER_0")
        XCTAssertEqual(key.encoded, "M_SPEAKER_0")
        XCTAssertEqual(SpeakerKey(encoded: key.encoded), key)
    }

    func testRoundTripSingle() {
        let key = SpeakerKey(track: .single, id: "SPEAKER_0")
        XCTAssertEqual(key.encoded, "SPEAKER_0")
        XCTAssertEqual(SpeakerKey(encoded: key.encoded), key)
    }

    // MARK: - Parse

    func testParseAppPrefix() {
        let key = SpeakerKey(encoded: "R_SPEAKER_1")
        XCTAssertEqual(key.track, .app)
        XCTAssertEqual(key.id, "SPEAKER_1")
    }

    func testParseMicPrefix() {
        let key = SpeakerKey(encoded: "M_SPEAKER_2")
        XCTAssertEqual(key.track, .mic)
        XCTAssertEqual(key.id, "SPEAKER_2")
    }

    func testParseSingleUnprefixed() {
        let key = SpeakerKey(encoded: "SPEAKER_3")
        XCTAssertEqual(key.track, .single)
        XCTAssertEqual(key.id, "SPEAKER_3")
    }

    // MARK: - Edge cases

    func testParseEmptyStringIsSingle() {
        let key = SpeakerKey(encoded: "")
        XCTAssertEqual(key.track, .single)
        XCTAssertEqual(key.id, "")
    }

    func testUnderscoreWithoutTrackPrefixStaysSingle() {
        // A raw id can contain underscores; only a leading R_/M_ marks a track.
        let key = SpeakerKey(encoded: "SPEAKER_10")
        XCTAssertEqual(key.track, .single)
        XCTAssertEqual(key.id, "SPEAKER_10")
    }

    // MARK: - Comparable / lexical ordering

    func testComparableSortsByEncoded() {
        // Later slices rely on encoded-lexical ordering to preserve UI/DTO order:
        // "M_..." < "R_..." < "SPEAKER..." lexically.
        let mic = SpeakerKey(track: .mic, id: "SPEAKER_0")
        let app = SpeakerKey(track: .app, id: "SPEAKER_0")
        let single = SpeakerKey(track: .single, id: "SPEAKER_0")
        XCTAssertEqual([single, app, mic].sorted(), [mic, app, single])
        XCTAssertTrue(mic < app)
        XCTAssertTrue(app < single)
    }
}
