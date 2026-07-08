#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The `/v1` wire shape is a stability contract. `JobStatusResponse` flattens
    /// the persisted `JobStatusDTO` plus an opt-in inline `transcript` onto one
    /// JSON object (issue #431). These lock that: with no transcript the bytes are
    /// exactly a `JobStatusDTO` (no `transcript` key), so a client sees no change
    /// unless it passes `?include=transcript`; with one it is a top-level sibling.
    final class JobStatusResponseTests: XCTestCase {
        private let dto = JobStatusDTO(
            jobID: "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
            state: .done,
            meetingTitle: "Daily Standup",
            transcriptPath: "/out/call.txt",
            protocolPath: nil,
            error: nil,
            warnings: [],
        )

        func testTranscriptKeyOmittedWhenNil() throws {
            let json = try XCTUnwrap(String(data: JSONEncoder().encode(JobStatusResponse(dto, transcript: nil)), encoding: .utf8))
            XCTAssertFalse(json.contains("\"transcript\""), "nil transcript must not appear in the JSON: \(json)")
            // The status fields are flattened onto the same object, not nested.
            XCTAssertTrue(json.contains("\"jobID\""))
            XCTAssertTrue(json.contains("\"transcriptPath\""))
            XCTAssertFalse(json.contains("\"status\""), "the base DTO must be flattened, not nested under a key")
        }

        func testTranscriptIsATopLevelSiblingWhenSet() throws {
            let data = try JSONEncoder().encode(JobStatusResponse(dto, transcript: "[00:00] S1: hello"))
            // Decodes back into the same envelope: status fields + transcript.
            let decoded = try JSONDecoder().decode(JobStatusResponse.self, from: data)
            XCTAssertEqual(decoded.transcript, "[00:00] S1: hello")
            XCTAssertEqual(decoded.status, dto)
            // And a plain JobStatusDTO decode still sees the flattened status fields.
            XCTAssertEqual(try JSONDecoder().decode(JobStatusDTO.self, from: data), dto)
        }
    }
#endif
