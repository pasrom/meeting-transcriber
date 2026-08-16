@testable import MeetingTranscriber
import XCTest

/// Pins the hand-written decoders behind the two shapes that gained a field.
///
/// They exist for one reason: a synthesized decoder demands every key, and both
/// shapes are already on disk from earlier versions. A throwing decode there is
/// not a lost field, it is a lost file — the pipeline snapshot carries a job's
/// pending speaker naming, and the terminal store carries the user's finished
/// jobs. Both are read leniently, so one unrecognised shape discards the lot
/// silently.
///
/// The tests are written against raw JSON rather than a round trip, because a
/// round trip encodes the new key and would pass against exactly the decoder
/// this guards against.
final class EchoDTODecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: XCTUnwrap(json.data(using: .utf8)))
    }

    // MARK: - EchoDetectionDTO

    /// A verdict written before dedup existed. Must read, and must report that
    /// nothing was removed rather than refusing the whole record.
    func testVerdictWithoutTheSuppressedCountStillDecodes() throws {
        let dto = try decode(EchoDetectionDTO.self, """
        {"detected":true,"affectedWindowShare":0.62,"windowsScored":34,"windowsAffected":21}
        """)
        XCTAssertTrue(dto.detected)
        XCTAssertEqual(dto.windowsScored, 34)
        XCTAssertEqual(dto.suppressedSegments, 0, "an older record removed nothing, because it could not")
    }

    func testVerdictWithTheSuppressedCountKeepsIt() throws {
        let dto = try decode(EchoDetectionDTO.self, """
        {"detected":true,"affectedWindowShare":1,"windowsScored":4,"windowsAffected":4,"suppressedSegments":6}
        """)
        XCTAssertEqual(dto.suppressedSegments, 6)
    }

    /// The fields that were always there stay required: a record missing one of
    /// those is genuinely broken, and quietly substituting a zero would report a
    /// recording as measured over no windows at all.
    func testVerdictMissingAnOriginalFieldIsRejected() {
        XCTAssertThrowsError(try decode(EchoDetectionDTO.self, """
        {"detected":true,"affectedWindowShare":0.5,"windowsScored":10}
        """))
    }

    func testVerdictSurvivesARoundTrip() throws {
        let original = try decode(EchoDetectionDTO.self, """
        {"detected":false,"affectedWindowShare":0,"windowsScored":4,"windowsAffected":0,"suppressedSegments":0}
        """)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(EchoDetectionDTO.self, from: data), original)
    }

    // MARK: - TimestampedSegment

    /// Segments persisted with speaker naming, from before either field existed.
    func testSegmentWithoutSpeakerOrSuppressedStillDecodes() throws {
        let segment = try decode(TimestampedSegment.self, """
        {"start":1.5,"end":4.25,"text":"hello"}
        """)
        XCTAssertEqual(segment.text, "hello")
        XCTAssertEqual(segment.speaker, "")
        XCTAssertFalse(segment.suppressed, "nothing was ever suppressed in a file written before this existed")
    }

    func testSegmentKeepsSuppressedAcrossARoundTrip() throws {
        var segment = TimestampedSegment(start: 0, end: 1, text: "echo of the far end", speaker: "Me")
        segment.suppressed = true
        let data = try JSONEncoder().encode(segment)
        let back = try JSONDecoder().decode(TimestampedSegment.self, from: data)
        XCTAssertTrue(back.suppressed, "a job restored after a restart must not resurrect the duplicates")
        XCTAssertEqual(back.speaker, "Me")
    }

    func testSegmentMissingTimesIsRejected() {
        XCTAssertThrowsError(try decode(TimestampedSegment.self, #"{"text":"no timing"}"#))
    }
}
