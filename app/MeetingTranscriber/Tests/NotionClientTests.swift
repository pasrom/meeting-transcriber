// swiftlint:disable file_length
import Foundation
@testable import MeetingTranscriber
import XCTest

// swiftlint:disable:next type_body_length
final class NotionClientTests: XCTestCase {
    // swiftlint:disable force_unwrapping
    func testExtractIDFromRawUUID() {
        let rawUUID = "c83b8b17-1234-4567-89ab-cdef01234567"
        let expected = "c83b8b171234456789abcdef01234567"
        XCTAssertEqual(NotionClient.extractID(from: rawUUID), expected)
    }

    func testExtractIDFromContinuousHex() {
        let hex = "c83b8b171234456789abcdef01234567"
        XCTAssertEqual(NotionClient.extractID(from: hex), hex.lowercased())
    }

    func testExtractIDFromNotionPageURL() {
        let url = "https://www.notion.so/myworkspace/Meeting-Transcriber-c83b8b171234456789abcdef01234567"
        let expected = "c83b8b171234456789abcdef01234567"
        XCTAssertEqual(NotionClient.extractID(from: url), expected)
    }

    func testExtractIDFromURLWithQueryParams() {
        let url = "https://www.notion.so/myworkspace/Meeting-Transcriber-c83b8b171234456789abcdef01234567?v=987654321&p=123"
        let expected = "c83b8b171234456789abcdef01234567"
        XCTAssertEqual(NotionClient.extractID(from: url), expected)
    }

    func testExtractIDFromInvalidString() {
        XCTAssertNil(NotionClient.extractID(from: "not-a-valid-id"))
        XCTAssertNil(NotionClient.extractID(from: ""))
    }

    func testListDatabasesParsesResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNotionURLProtocol.self]
        let session = URLSession(configuration: config)

        let json = """
        {
          "object": "list",
          "results": [
            {
              "object": "database",
              "id": "11111111-2222-3333-4444-555555555555",
              "title": [
                { "type": "text", "plain_text": "Meeting Transcriber" }
              ]
            },
            {
              "object": "database",
              "id": "66666666-7777-8888-9999-000000000000",
              "title": [
                { "type": "text", "plain_text": "Sprint Planning" }
              ]
            }
          ]
        }
        """

        MockNotionURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = NotionClient(apiKey: "test-key", session: session)
        let databases = try await client.listDatabases()

        XCTAssertEqual(databases.count, 2)
        XCTAssertEqual(databases[0].id, "11111111222233334444555555555555")
        XCTAssertEqual(databases[0].title, "Meeting Transcriber")
        XCTAssertEqual(databases[1].id, "66666666777788889999000000000000")
        XCTAssertEqual(databases[1].title, "Sprint Planning")
    }

    func testListPagesParsesResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNotionURLProtocol.self]
        let session = URLSession(configuration: config)

        let json = """
        {
          "object": "list",
          "results": [
            {
              "object": "page",
              "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
              "properties": {
                "title": {
                  "type": "title",
                  "title": [
                    { "type": "text", "plain_text": "Weekly Notes" }
                  ]
                }
              }
            }
          ]
        }
        """

        MockNotionURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = NotionClient(apiKey: "test-key", session: session)
        let pages = try await client.listPages()

        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].id, "aaaaaaaabbbbccccddddeeeeeeeeeeee")
        XCTAssertEqual(pages[0].title, "Weekly Notes")
    }

    func testCheckDatabaseCompatibilityDetectsMissingColumns() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNotionURLProtocol.self]
        let session = URLSession(configuration: config)

        let json = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Custom Meeting Notes" }],
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" }
          }
        }
        """

        MockNotionURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = NotionClient(apiKey: "test-key", session: session)
        let status = try await client.checkDatabaseCompatibility(id: "11111111-2222-3333-4444-555555555555")

        XCTAssertEqual(status.title, "Custom Meeting Notes")
        XCTAssertEqual(status.titleColumnName, "Name")
        XCTAssertFalse(status.hasAllOptionalColumns)
        XCTAssertEqual(status.missingColumns, ["Tags", "Date"])
    }

    func testUpgradeDatabaseSchemaSendsPatch() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNotionURLProtocol.self]
        let session = URLSession(configuration: config)

        var didSendPatch = false

        MockNotionURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            )!

            if request.httpMethod == "PATCH" {
                didSendPatch = true
            }

            let json = """
            {
              "object": "database",
              "id": "11111111-2222-3333-4444-555555555555",
              "title": [{ "type": "text", "plain_text": "Upgraded DB" }],
              "properties": {
                "Title": { "id": "title", "name": "Title", "type": "title" },
                "Tags": { "id": "tags", "name": "Tags", "type": "multi_select" },
                "Date": { "id": "date", "name": "Date", "type": "date" },
                "Created time": { "id": "c_time", "name": "Created time", "type": "created_time" },
                "Last edited time": { "id": "e_time", "name": "Last edited time", "type": "last_edited_time" }
              }
            }
            """
            return (response, json.data(using: .utf8)!)
        }

        let client = NotionClient(apiKey: "test-key", session: session)
        let status = try await client.upgradeDatabaseSchema(
            id: "11111111-2222-3333-4444-555555555555",
            missingColumns: ["Tags", "Date"],
        )

        XCTAssertTrue(didSendPatch)
        XCTAssertTrue(status.hasAllOptionalColumns)
        XCTAssertTrue(status.missingColumns.isEmpty)
    }

    func testCreateDatabaseEncodesParentTitleAndColumns() async throws {
        var requestBody: Data?
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/databases")
            requestBody = Self.bodyData(from: request)
            let json = #"{"id":"11111111-2222-3333-4444-555555555555"}"#
            return (Self.okResponse(for: request), Data(json.utf8))
        }

        let id = try await client.createDatabase(
            parentPageID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", title: "Team Notes",
        )

        XCTAssertEqual(id, "11111111222233334444555555555555")
        let body = try XCTUnwrap(requestBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parent = try XCTUnwrap(object["parent"] as? [String: String])
        XCTAssertEqual(parent["type"], "page_id")
        XCTAssertEqual(parent["page_id"], "aaaaaaaabbbbccccddddeeeeeeeeeeee")
        let title = try XCTUnwrap((object["title"] as? [[String: Any]])?.first)
        XCTAssertEqual(title["type"] as? String, "text")
        XCTAssertEqual((title["text"] as? [String: String])?["content"], "Team Notes")
        let properties = try XCTUnwrap(object["properties"] as? [String: [String: Any]])
        let columns = [
            "Title": "title",
            "Tags": "multi_select",
            "Date": "date",
            "Created time": "created_time",
            "Last edited time": "last_edited_time",
        ]
        XCTAssertEqual(Set(properties.keys), Set(columns.keys))
        for (name, kind) in columns {
            XCTAssertNotNil(properties[name]?[kind] as? [String: Any])
        }
    }

    func testGetBotInfoParsesResponse() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNotionURLProtocol.self]
        let session = URLSession(configuration: config)

        let json = """
        {
          "object": "user",
          "id": "408972f0-50ff-8101-9063-002768c0bd18",
          "name": "Meeting-Transcriber",
          "type": "bot",
          "bot": {
            "owner": { "type": "workspace", "workspace": true },
            "workspace_name": "Acme Workspace"
          }
        }
        """

        MockNotionURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            )!
            return (response, json.data(using: .utf8)!)
        }

        let client = NotionClient(apiKey: "test-key", session: session)
        let info = try await client.getBotInfo()

        XCTAssertEqual(info.name, "Meeting-Transcriber")
        XCTAssertEqual(info.workspaceName, "Acme Workspace")
    }

    func testSchemaResolutionPrefersConventionalColumnNames() async throws {
        let json = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Team Notes" }],
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" },
            "Alpha Date": { "id": "d1", "name": "Alpha Date", "type": "date" },
            "Date": { "id": "d2", "name": "Date", "type": "date" },
            "Labels": { "id": "m1", "name": "Labels", "type": "multi_select" },
            "Tags": { "id": "m2", "name": "Tags", "type": "multi_select" },
            "Created time": { "id": "ct", "name": "Created time", "type": "created_time" },
            "Last edited time": { "id": "le", "name": "Last edited time", "type": "last_edited_time" }
          }
        }
        """

        let client = makeClient(json: json)
        let status = try await client.checkDatabaseCompatibility(id: "11111111-2222-3333-4444-555555555555")

        XCTAssertEqual(status.titleColumnName, "Name")
        XCTAssertEqual(status.dateColumnName, "Date")
        XCTAssertEqual(status.tagsColumnName, "Tags")
        XCTAssertTrue(status.hasAllOptionalColumns)
    }

    func testSchemaResolutionIgnoresUnrecognizedColumns() async throws {
        let json = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Team Notes" }],
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" },
            "Due date": { "id": "d", "name": "Due date", "type": "date" },
            "Status": { "id": "m", "name": "Status", "type": "multi_select" }
          }
        }
        """

        let client = makeClient(json: json)
        let status = try await client.checkDatabaseCompatibility(id: "11111111-2222-3333-4444-555555555555")

        XCTAssertNil(status.dateColumnName)
        XCTAssertNil(status.tagsColumnName)
        XCTAssertEqual(status.missingColumns, ["Tags", "Date"])
    }

    func testExportMeetingUsesResolvedColumns() async throws {
        let schemaJSON = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Custom Notes" }],
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" },
            "When": { "id": "d", "name": "When", "type": "date" },
            "Speakers": { "id": "m", "name": "Speakers", "type": "multi_select" },
            "Created time": { "id": "ct", "name": "Created time", "type": "created_time" },
            "Last edited time": { "id": "le", "name": "Last edited time", "type": "last_edited_time" }
          }
        }
        """
        let pageJSON = #"{"object":"page","id":"page-1","url":"https://www.notion.so/page-1"}"#

        var pageBody: Data?
        var didPatch = false
        let client = makeClient(databaseID: "11111111222233334444555555555555") { request in
            if request.httpMethod == "PATCH" { didPatch = true }
            if request.url?.path.hasSuffix("/pages") == true {
                pageBody = Self.bodyData(from: request)
                return (Self.okResponse(for: request), Data(pageJSON.utf8))
            }
            return (Self.okResponse(for: request), Data(schemaJSON.utf8))
        }

        let result = try await client.exportMeeting(
            title: "Weekly Sync",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            tags: ["Alice", "Bob"],
            markdown: "# Weekly Sync\n\nSummary.",
            transcript: nil,
        )

        XCTAssertEqual(result.pageID, "page-1")
        XCTAssertFalse(didPatch)

        let body = try XCTUnwrap(pageBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let icon = try XCTUnwrap(json["icon"] as? [String: String])
        XCTAssertEqual(icon["type"], "emoji")
        XCTAssertEqual(icon["emoji"], "🎙️")
        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        XCTAssertNotNil(properties["Name"])
        XCTAssertNotNil(properties["When"])
        XCTAssertNotNil(properties["Speakers"])
        XCTAssertNil(properties["Title"])
        XCTAssertNil(properties["Date"])
        XCTAssertNil(properties["Tags"])
    }

    func testExportMeetingOmitsMissingOptionalColumnsInsteadOfPatching() async throws {
        let schemaJSON = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Minimal DB" }],
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" }
          }
        }
        """
        let pageJSON = #"{"object":"page","id":"page-2","url":null}"#

        var didPatch = false
        var pageBody: Data?
        let client = makeClient(databaseID: "11111111222233334444555555555555") { request in
            if request.httpMethod == "PATCH" {
                didPatch = true
                return (Self.okResponse(for: request), Data(schemaJSON.utf8))
            }
            if request.url?.path.hasSuffix("/pages") == true {
                pageBody = Self.bodyData(from: request)
                return (Self.okResponse(for: request), Data(pageJSON.utf8))
            }
            return (Self.okResponse(for: request), Data(schemaJSON.utf8))
        }

        let result = try await client.exportMeeting(
            title: "Weekly Sync",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            tags: ["Alice"],
            markdown: "# Weekly Sync",
            transcript: nil,
        )

        XCTAssertFalse(didPatch)
        XCTAssertEqual(result.omittedProperties, ["Date", "Tags"])

        let page = try XCTUnwrap(pageBody)
        let pageJSONObject = try XCTUnwrap(JSONSerialization.jsonObject(with: page) as? [String: Any])
        let pageProperties = try XCTUnwrap(pageJSONObject["properties"] as? [String: Any])
        XCTAssertNil(pageProperties["Date"])
        XCTAssertNil(pageProperties["Tags"])
    }

    func testExportMeetingUpdatesAnExistingEmptyPage() async throws {
        let schemaJSON = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Custom Notes" }],
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" }
          }
        }
        """
        let pageID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let pageJSON = #"{"object":"page","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","url":"https://www.notion.so/page-1"}"#
        var didCreate = false
        var didAppend = false

        let client = makeClient(databaseID: "11111111222233334444555555555555") { request in
            let path = request.url?.path ?? ""
            if path.contains("/blocks/") && path.hasSuffix("/children") {
                if request.httpMethod == "PATCH" {
                    didAppend = true
                    return (Self.okResponse(for: request), Data(#"{"object":"list","results":[]}"#.utf8))
                }
                return (Self.okResponse(for: request), Data(#"{"object":"list","results":[]}"#.utf8))
            }
            if path.hasSuffix("/pages") && request.httpMethod == "POST" {
                didCreate = true
            }
            if path.contains("/pages/") {
                return (Self.okResponse(for: request), Data(pageJSON.utf8))
            }
            return (Self.okResponse(for: request), Data(schemaJSON.utf8))
        }

        let result = try await client.exportMeeting(
            title: "Weekly Sync",
            date: nil,
            tags: [],
            markdown: "# Weekly Sync",
            transcript: nil,
            existingPageID: pageID,
        )

        XCTAssertFalse(didCreate)
        XCTAssertTrue(didAppend)
        XCTAssertEqual(result.pageID, pageID)
        XCTAssertTrue(result.updatedExistingPage)
    }

    func testExportMeetingReplacesExistingPageContent() async throws {
        let schemaJSON = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Custom Notes" }],
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" }
          }
        }
        """
        let pageID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let pageJSON = #"{"object":"page","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","url":"https://www.notion.so/page-1"}"#
        var didAppend = false
        var archivedBlocks: [String] = []

        let client = makeClient(databaseID: "11111111222233334444555555555555") { request in
            let path = request.url?.path ?? ""
            if path.contains("/blocks/") && path.hasSuffix("/children") {
                if request.httpMethod == "PATCH" {
                    didAppend = true
                    return (Self.okResponse(for: request), Data("{}".utf8))
                }
                let secondPage = request.url?.query?.contains("start_cursor") == true
                let json = secondPage
                    ? #"{"results":[{"id":"block-2"}],"has_more":false}"#
                    : #"{"results":[{"id":"block-1"}],"has_more":true,"next_cursor":"next"}"#
                return (Self.okResponse(for: request), Data(json.utf8))
            }
            if request.httpMethod == "DELETE" {
                archivedBlocks.append(path.components(separatedBy: "/").last ?? "")
                XCTAssertTrue(didAppend, "Keep old content until the new content has been written")
                return (Self.okResponse(for: request), Data("{}".utf8))
            }
            if path.contains("/pages/") {
                return (Self.okResponse(for: request), Data(pageJSON.utf8))
            }
            return (Self.okResponse(for: request), Data(schemaJSON.utf8))
        }

        let result = try await client.exportMeeting(
            title: "Weekly Sync",
            date: nil,
            tags: [],
            markdown: "# Weekly Sync",
            transcript: nil,
            existingPageID: pageID,
        )

        XCTAssertTrue(didAppend)
        XCTAssertEqual(archivedBlocks, ["block-1", "block-2"])
        XCTAssertTrue(result.updatedExistingPage)
    }

    func testExportMeetingRecordsThePageBeforeAppendingBlocks() async {
        let schemaJSON = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Custom Notes" }],
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" }
          }
        }
        """
        let pageID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let pageJSON = #"{"object":"page","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","url":"https://www.notion.so/page-1"}"#

        let client = makeClient(databaseID: "11111111222233334444555555555555") { request in
            let path = request.url?.path ?? ""
            if path.contains("/blocks/") && path.hasSuffix("/children") {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"],
                )!
                return (response, Data(#"{"object":"error","status":500,"code":"internal_server_error","message":"boom"}"#.utf8))
            }
            if path.hasSuffix("/pages") && request.httpMethod == "POST" {
                return (Self.okResponse(for: request), Data(pageJSON.utf8))
            }
            return (Self.okResponse(for: request), Data(schemaJSON.utf8))
        }

        let recordedPage = LockedBox<String>()
        do {
            _ = try await client.exportMeeting(
                title: "Weekly Sync",
                date: nil,
                tags: [],
                markdown: String(repeating: "A paragraph.\n\n", count: 150),
                transcript: nil,
            ) { page in recordedPage.set(page.pageID) }
            XCTFail("Expected the block append to fail")
        } catch {
            XCTAssertEqual(recordedPage.get(), pageID)
        }
    }

    func testRetryAfterOverflowFailureWritesTheEntireProtocol() async throws {
        let pageID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let schema = #"{"id":"11111111222233334444555555555555","properties":{"Name":{"type":"title"}}}"#
        let page = #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","url":"https://www.notion.so/page-1"}"#
        var storedBlocks: [String] = []
        var creates = 0
        var failAppend = true
        let client = makeClient(databaseID: "11111111222233334444555555555555") { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/databases/11111111222233334444555555555555") {
                return (Self.okResponse(for: request), Data(schema.utf8))
            }
            if path.hasSuffix("/pages") {
                creates += 1
                storedBlocks = (0 ..< 100).map { "block-\($0)" }
                return (Self.okResponse(for: request), Data(page.utf8))
            }
            if path.hasSuffix("/children") {
                if request.httpMethod == "GET" {
                    let objects = storedBlocks.map { ["id": $0, "type": "paragraph"] }
                    let data = try JSONSerialization.data(withJSONObject: ["results": objects, "has_more": false])
                    return (Self.okResponse(for: request), data)
                }
                if failAppend {
                    failAppend = false
                    let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                    return (response, Data(#"{"message":"temporary failure"}"#.utf8))
                }
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Self.bodyData(from: request))) as? [String: Any])
                let children = try XCTUnwrap(object["children"] as? [[String: Any]])
                storedBlocks += (storedBlocks.count ..< storedBlocks.count + children.count).map { "new-\($0)" }
                return (Self.okResponse(for: request), Data("{}".utf8))
            }
            if request.httpMethod == "DELETE" {
                storedBlocks.removeAll { $0 == path.components(separatedBy: "/").last }
                return (Self.okResponse(for: request), Data("{}".utf8))
            }
            return (Self.okResponse(for: request), Data(page.utf8))
        }
        let markdown = String(repeating: "Paragraph.\n\n", count: 150)
        do {
            _ = try await client.exportMeeting(title: "Notes", date: nil, tags: [], markdown: markdown, transcript: nil)
            XCTFail("Expected first overflow append to fail")
        } catch {
            XCTAssertEqual(storedBlocks.count, 100)
        }
        _ = try await client.exportMeeting(
            title: "Notes", date: nil, tags: [], markdown: markdown, transcript: nil, existingPageID: pageID,
        )
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(storedBlocks.count, 150)
        XCTAssertTrue(storedBlocks.allSatisfy { $0.hasPrefix("new-") })
    }

    func testArchivedOrMissingPageIsReplaced() async throws {
        for status in [200, 404] {
            var created = false
            let client = makeClient(databaseID: "11111111222233334444555555555555") { request in
                let path = request.url?.path ?? ""
                if path.contains("/databases/") {
                    return (Self.okResponse(for: request), Data(#"{"id":"database","properties":{"Name":{"type":"title"}}}"#.utf8))
                }
                if path.hasSuffix("/pages") {
                    created = true
                    return (Self.okResponse(for: request), Data(#"{"id":"new-page"}"#.utf8))
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"id":"old-page","archived":true,"status":404,"code":"object_not_found"}"#.utf8))
            }
            let result = try await client.exportMeeting(
                title: "Notes", date: nil, tags: [], markdown: "Notes", transcript: nil,
                existingPageID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            )
            XCTAssertTrue(created)
            XCTAssertEqual(result.pageID, "new-page")
        }
    }

    func testHTTPErrorUsesResponseStatusEvenWhenJSONHasNoStatus() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":"object_not_found","message":"Not shared"}"#.utf8))
        }
        do {
            _ = try await client.getBotInfo()
            XCTFail("Expected 404")
        } catch let error as NotionClientError {
            XCTAssertTrue(error.localizedDescription.contains("404"))
            XCTAssertTrue(error.localizedDescription.contains("Not shared"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testMultiSelectNamesSanitizeCommasAndDeduplicate() throws {
        let data = try JSONEncoder().encode(NotionPropertyValue.multiSelect([
            "Smith, John",
            "Smith John",
            " , ",
            "Alice",
            "S1",
            "SPEAKER_0",
            "Unknown",
            "Remote",
        ]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let values = try XCTUnwrap(object["multi_select"] as? [[String: String]])
        XCTAssertEqual(values.compactMap { $0["name"] }, ["Smith John", "Alice"])
    }

    func testRateLimitIsRetried() async throws {
        let json = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Team Notes" }],
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" }
          }
        }
        """
        var calls = 0
        let client = makeClient { request in
            calls += 1
            if calls == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"],
                )!
                return (response, Data())
            }
            return (Self.okResponse(for: request), Data(json.utf8))
        }

        _ = try await client.checkDatabaseCompatibility(id: "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(calls, 2)
    }

    func testNonFiniteRetryAfterFallsBackInsteadOfTrapping() async throws {
        var calls = 0
        let client = makeClient { request in
            calls += 1
            if calls == 1 {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 429, httpVersion: nil,
                    headerFields: ["Retry-After": "nan"],
                )!
                return (response, Data())
            }
            let json = """
            {"object":"database","id":"11111111-2222-3333-4444-555555555555","title":[],
             "properties":{"Name":{"id":"title","name":"Name","type":"title"}}}
            """
            return (Self.okResponse(for: request), Data(json.utf8))
        }

        _ = try await client.checkDatabaseCompatibility(id: "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(calls, 2)
    }

    func testExportFailureReasonsNameTheCauseWithoutResponseText() {
        let http = { (status: Int) in
            NotionClientError.exportFailureReason(for: NotionClientError.httpError(statusCode: status, message: "secret text"))
        }
        XCTAssertEqual(http(401), "invalid API token")
        XCTAssertEqual(http(404), "not shared with the integration")
        XCTAssertEqual(http(400), "rejected by Notion, HTTP 400")
        XCTAssertEqual(http(503), "Notion server error, HTTP 503")
        XCTAssertEqual(NotionClientError.exportFailureReason(for: URLError(.timedOut)), "request timed out")
        XCTAssertEqual(NotionClientError.exportFailureReason(for: URLError(.notConnectedToInternet)), "network error")
    }

    func testSearchFollowsPagination() async throws {
        let firstJSON = """
        {
          "object": "list",
          "results": [
            { "object": "database", "id": "11111111-2222-3333-4444-555555555555",
              "title": [{ "type": "text", "plain_text": "First" }] }
          ],
          "has_more": true,
          "next_cursor": "cursor-2"
        }
        """
        let secondJSON = """
        {
          "object": "list",
          "results": [
            { "object": "database", "id": "66666666-7777-8888-9999-000000000000",
              "title": [{ "type": "text", "plain_text": "Second" }] }
          ],
          "has_more": false,
          "next_cursor": null
        }
        """
        var callCount = 0
        let client = makeClient { request in
            callCount += 1
            let json = callCount == 1 ? firstJSON : secondJSON
            return (Self.okResponse(for: request), Data(json.utf8))
        }

        let databases = try await client.listDatabases()

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(databases.map(\.title), ["First", "Second"])
    }

    func testListDatabasesFiltersTrashedAndArchivedResults() async throws {
        let json = """
        {
          "object": "list",
          "results": [
            { "object": "database", "id": "11111111-2222-3333-4444-555555555555",
              "title": [{ "type": "text", "plain_text": "Active" }] },
            { "object": "database", "id": "22222222-3333-4444-5555-666666666666",
              "title": [{ "type": "text", "plain_text": "Trashed" }],
              "in_trash": true },
            { "object": "database", "id": "33333333-4444-5555-6666-777777777777",
              "title": [{ "type": "text", "plain_text": "Archived" }],
              "archived": true }
          ],
          "has_more": false,
          "next_cursor": null
        }
        """

        let client = makeClient(json: json)
        let databases = try await client.listDatabases()

        XCTAssertEqual(databases.map(\.title), ["Active"])
    }

    func testCheckDatabaseCompatibilityRejectsTrashedDatabase() async throws {
        let json = """
        {
          "object": "database",
          "id": "11111111-2222-3333-4444-555555555555",
          "title": [{ "type": "text", "plain_text": "Trashed" }],
          "in_trash": true,
          "properties": {
            "Name": { "id": "title", "name": "Name", "type": "title" }
          }
        }
        """

        let client = makeClient(json: json)

        do {
            _ = try await client.checkDatabaseCompatibility(id: "11111111-2222-3333-4444-555555555555")
            XCTFail("Expected a trashed database to be rejected")
        } catch let error as NotionClientError {
            XCTAssertEqual(error, .databaseInTrash)
        }
    }

    func testSchemaResolutionRecognizesRenamedOptionalColumns() {
        let properties: [String: NotionDatabaseResponse.PropertyInfo] = [
            "Name": .init(type: "title"),
            "Tags (Meeting Transcriber)": .init(type: "multi_select"),
            "Date (Meeting Transcriber)": .init(type: "date"),
        ]

        let schema = NotionResolvedSchema.resolve(properties)

        XCTAssertEqual(schema.tagsColumnName, "Tags (Meeting Transcriber)")
        XCTAssertEqual(schema.dateColumnName, "Date (Meeting Transcriber)")
    }

    func testColumnDefinitionsAvoidExistingNames() {
        let existing: [String: NotionDatabaseResponse.PropertyInfo] = [
            "Date": .init(type: "rich_text"),
            "Tags": .init(type: "rich_text"),
        ]

        let definitions = NotionColumnDefinition.definitions(
            for: ["Date", "Tags"],
            existingProperties: existing,
        )

        XCTAssertEqual(
            definitions.map(\.name),
            ["Date (Meeting Transcriber)", "Tags (Meeting Transcriber)"],
        )
        XCTAssertEqual(definitions.map(\.kind), [.date, .tags])
    }

    private func makeClient(json: String) -> NotionClient {
        makeClient { request in
            (Self.okResponse(for: request), Data(json.utf8))
        }
    }

    private func makeClient(
        databaseID: String? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
    ) -> NotionClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNotionURLProtocol.self]
        MockNotionURLProtocol.requestHandler = handler
        return NotionClient(
            apiKey: "test-key",
            databaseID: databaseID,
            session: URLSession(configuration: config),
        )
    }

    private static func okResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = buffer.withUnsafeMutableBytes { bytes in
                stream.read(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: bytes.count)
            }
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// swiftlint:enable force_unwrapping

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private class MockNotionURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("No handler provided for request: \(request)")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
