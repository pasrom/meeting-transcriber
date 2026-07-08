#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// Pure query-string parsing for the `?include=transcript` opt-in on the
    /// `/v1` surface (issue #431).
    final class DebugRPCServerV1QueryTests: XCTestCase {
        func testWantsInlineTranscriptFalseWithoutQuery() {
            XCTAssertFalse(DebugRPCServer.wantsInlineTranscript(target: "/v1/transcribe"))
            XCTAssertFalse(DebugRPCServer.wantsInlineTranscript(target: "/v1/jobs/\(UUID().uuidString)"))
        }

        func testWantsInlineTranscriptTrueForIncludeTranscript() {
            XCTAssertTrue(DebugRPCServer.wantsInlineTranscript(target: "/v1/transcribe?include=transcript"))
        }

        func testWantsInlineTranscriptTrueWithinCommaList() {
            XCTAssertTrue(DebugRPCServer.wantsInlineTranscript(target: "/v1/transcribe?include=protocol,transcript"))
        }

        func testWantsInlineTranscriptTrueAlongsideOtherParams() {
            XCTAssertTrue(DebugRPCServer.wantsInlineTranscript(
                target: "/v1/jobs/\(UUID().uuidString)?wait=1&include=transcript",
            ))
        }

        func testWantsInlineTranscriptIsCaseInsensitiveOnValue() {
            XCTAssertTrue(DebugRPCServer.wantsInlineTranscript(target: "/v1/transcribe?include=Transcript"))
        }

        func testWantsInlineTranscriptFalseForUnrelatedInclude() {
            XCTAssertFalse(DebugRPCServer.wantsInlineTranscript(target: "/v1/transcribe?include=protocol"))
            XCTAssertFalse(DebugRPCServer.wantsInlineTranscript(target: "/v1/transcribe?other=transcript"))
        }
    }
#endif
