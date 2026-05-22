@testable import MeetingTranscriber
import XCTest

/// `LiveCaptionLine` + `LiveCaptionChannel` are serialised into the RPC
/// `/state.liveCaptions.recentFinals[]` payload that `mt-cli` + the
/// `e2e-live-captions.sh` driver depend on. Renaming an enum case
/// (e.g. `.mic` → `.local`) would silently break that wire format. These
/// tests pin the canonical JSON shape so a refactor surfaces locally
/// instead of bricking the e2e driver on CI.
final class LiveCaptionWireFormatTests: XCTestCase {
    func testChannelMicEncodesAsString() throws {
        let data = try JSONEncoder().encode(LiveCaptionChannel.mic)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"mic\"")
    }

    func testChannelAppEncodesAsString() throws {
        let data = try JSONEncoder().encode(LiveCaptionChannel.app)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"app\"")
    }

    func testChannelDecodesFromString() throws {
        let mic = try JSONDecoder().decode(LiveCaptionChannel.self, from: Data("\"mic\"".utf8))
        let app = try JSONDecoder().decode(LiveCaptionChannel.self, from: Data("\"app\"".utf8))
        XCTAssertEqual(mic, .mic)
        XCTAssertEqual(app, .app)
    }

    func testLineRoundTripPreservesValues() throws {
        let original = LiveCaptionLine(channel: .app, text: "Hello world")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LiveCaptionLine.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLineEncodesExpectedShape() throws {
        let line = LiveCaptionLine(channel: .mic, text: "Du sprichst")
        let data = try JSONEncoder().encode(line)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
        )
        // Two top-level keys, no nested or renamed fields. If anyone
        // wraps the line in a container or renames `text` → `content`,
        // this fails before it can break mt-cli's snapshot expectations.
        XCTAssertEqual(json["channel"] as? String, "mic")
        XCTAssertEqual(json["text"] as? String, "Du sprichst")
        XCTAssertEqual(json.count, 2)
    }
}
