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
        let original = LiveCaptionLine(channel: .app, text: "Hello world", speaker: "Anna")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LiveCaptionLine.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLineEncodesExpectedShape() throws {
        let line = LiveCaptionLine(channel: .mic, text: "Du sprichst", speaker: "Roman")
        let data = try JSONEncoder().encode(line)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
        )
        // Three top-level keys. Pins the addition of `speaker` (slice 2
        // live speaker matching) so a future rename or removal — or a
        // wrapper that nests these in a container — breaks here before it
        // bricks `mt-cli` / `e2e-live-captions.sh`.
        XCTAssertEqual(json["channel"] as? String, "mic")
        XCTAssertEqual(json["text"] as? String, "Du sprichst")
        XCTAssertEqual(json["speaker"] as? String, "Roman")
        XCTAssertEqual(json.count, 3)
    }

    func testLineDecodesFromWireFormat() throws {
        let payload = Data("""
        {"channel":"app","text":"Hi there","speaker":"Anna"}
        """.utf8)
        let line = try JSONDecoder().decode(LiveCaptionLine.self, from: payload)
        XCTAssertEqual(line.channel, .app)
        XCTAssertEqual(line.text, "Hi there")
        XCTAssertEqual(line.speaker, "Anna")
    }
}
