import Foundation
@testable import MeetingTranscriber
import XCTest

final class ContextPolicyTests: XCTestCase {
    func testConstraintsAcceptTypedNestedObjectsAndRejectExtraProperties() throws {
        let schema = try decode(#"""
        {"type":"object","properties":{"filter":{"type":"object","properties":{
          "kinds":{"type":"array","items":{"type":"string","enum":["project","tool"]},"uniqueItems":true},
          "weight":{"type":"number","exclusiveMinimum":0,"maximum":1,"examples":[0.1]}
        },"required":["kinds"],"additionalProperties":false}},"required":["filter"],"additionalProperties":false}
        """#)
        let catalog = try XCTUnwrap(ContextSchema.catalogSchema(schema))
        XCTAssertNil(catalog["properties"]?["filter"]?["properties"]?["weight"]?["examples"])
        let valid = try decode(#"{"filter":{"kinds":["project","tool"],"weight":1}}"#)
        XCTAssertTrue(ContextSchema.accepts(valid, schema: catalog))
        for arguments in [
            #"{"filter":{"kinds":["project","project"]}}"#,
            #"{"filter":{"kinds":["unknown"]}}"#,
            #"{"filter":{"kinds":[],"weight":0}}"#,
            #"{"filter":{"kinds":[],"weight":true}}"#,
            #"{"filter":{"kinds":[],"extra":"bad"}}"#,
            #"{"filter":{"weight":1}}"#,
        ] {
            XCTAssertFalse(try ContextSchema.accepts(decode(arguments), schema: catalog), arguments)
        }
    }

    func testUnknownSchemaConstraintsFailClosed() throws {
        for source in [
            #"{"type":"object","allOf":[]}"#,
            #"{"type":"object","properties":{"x":{"type":"string","pattern":"x"}}}"#,
            ##"{"type":"object","properties":{"x":{"$ref":"#/definitions/x"}}}"##,
            #"{"type":"object","additionalProperties":"false"}"#,
        ] {
            XCTAssertNil(try ContextSchema.catalogSchema(decode(source)))
        }
    }

    func testPlanRequiresGroundedMentionAndRejectsDumpOrSecrets() throws {
        let transcript = "[00:20] [Speaker A] Finish fly wheel curation before release."
        let segments = ["seg-1": transcript]
        let valid = #"""
        {"request_id":"one","tool_id":"allowed","arguments":{"term":"fly wheel project"},
         "mentions":[{"segment_id":"seg-1","surface_text":"fly wheel"}]}
        """#
        let credential = "fixture-secret-value"
        func lookup(_ payload: String) throws -> ContextLookup? {
            try ContextLookup(decode(payload), segments: segments, transcript: transcript, secrets: [credential])
        }
        XCTAssertNotNil(try lookup(valid))
        XCTAssertNil(try lookup(valid.replacingOccurrences(of: "seg-1", with: "seg-8")))
        XCTAssertNil(try lookup(valid.replacingOccurrences(of: "fly wheel\"}", with: "unspoken\"}")))
        XCTAssertNil(try lookup(valid.replacingOccurrences(of: "fly wheel project", with: "Finish fly wheel curation before release")))
        XCTAssertNil(try lookup(valid.replacingOccurrences(of: "fly wheel project", with: credential)))
        XCTAssertNil(try lookup(valid.replacingOccurrences(of: "term", with: "password")))
    }

    func testOrdinaryBasicPhrasesDoNotTriggerCredentialDetection() {
        XCTAssertFalse(ContextDataSafety.containsSensitive("A basic understanding is enough.", secrets: []))
        let credential = Data("fixture-user:fixture-password".utf8).base64EncodedString()
        XCTAssertTrue(ContextDataSafety.containsSensitive("Basic \(credential)", secrets: []))
        XCTAssertTrue(ContextDataSafety.containsSensitive("Bearer fixture-token-12345", secrets: []))
    }

    func testToolNeedsExplicitReadOnlyHintAndCannotDeclareDestructiveBehavior() throws {
        let tool = try decode(#"{"name":"lookup","inputSchema":{"type":"object","properties":{}}}"#)
        let fields = try XCTUnwrap(tool.object)
        XCTAssertFalse(try XCTUnwrap(MCPTool(wire: tool)).permitsReadOnlyApproval)
        for (annotations, eligible) in [
            (#"{"readOnlyHint":false}"#, false),
            (#"{"readOnlyHint":true,"destructiveHint":true}"#, false),
            (#"{"readOnlyHint":true}"#, true),
        ] {
            var annotated = fields
            annotated["annotations"] = try decode(annotations)
            XCTAssertEqual(try XCTUnwrap(MCPTool(wire: .object(annotated))).permitsReadOnlyApproval, eligible)
        }
    }

    func testExistingNotesChangeBlocksStaleReplacement() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("meeting.md")
        XCTAssertEqual(try MeetingContextFiles.ExistingNotes.capture(url), .absent)
        try MeetingContextFiles.replaceNotes("# First", at: url, expected: .absent)
        let original = try MeetingContextFiles.ExistingNotes.capture(url)
        try MeetingContextFiles.replaceNotes("# New", at: url, expected: original)
        XCTAssertThrowsError(try MeetingContextFiles.replaceNotes("# Stale", at: url, expected: original))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# New")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    private func decode(_ json: String) throws -> ContextJSON {
        try JSONDecoder().decode(ContextJSON.self, from: Data(json.utf8))
    }
}
