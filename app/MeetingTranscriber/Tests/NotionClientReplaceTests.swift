import Foundation
@testable import MeetingTranscriber
import XCTest

/// A replace that is interrupted part-way through its deletes must neither make
/// the page grow on the next attempt nor need one fully successful pass to
/// converge. The stateful fake below behaves like a Notion page: appends add
/// root blocks at the end, deletes remove them, and a delete can be made to fail.
final class NotionClientReplaceTests: XCTestCase {
    private let databaseID = "11111111222233334444555555555555"
    private let pageID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func markdown(_ prefix: String, count: Int) -> String {
        (1 ... count).map { "\(prefix) paragraph \($0)." }.joined(separator: "\n\n")
    }

    // MARK: - Convergence

    func testRepeatedlyInterruptedReplaceNeverGrowsThePageAndConvergesWithoutAFullPass() async throws {
        let page = FakeNotionPage(initial: texts("Old", count: 5))
        let client = page.makeClient(databaseID: databaseID)
        let newContent = markdown("New", count: 5)

        // Pass 1: the append lands, then the deletes start failing after two.
        page.deletePlan = .succeedThenFail(successes: 2)
        await assertFails(client, markdown: newContent)
        XCTAssertEqual(page.texts, ["Old paragraph 3.", "Old paragraph 4.", "Old paragraph 5."] + texts("New", count: 5))
        let sizeAfterFirstFailure = page.texts.count

        // Pass 2 fails again, after one delete. The page must not take a second
        // full copy, and it must still have made progress.
        page.deletePlan = .succeedThenFail(successes: 1)
        await assertFails(client, markdown: newContent)
        XCTAssertLessThanOrEqual(page.texts.count, sizeAfterFirstFailure, "A failed replace must not make the page grow")
        XCTAssertEqual(page.texts.filter { $0.hasPrefix("New") }.count, 5, "Exactly one copy of the new content")
        XCTAssertEqual(page.texts.filter { $0.hasPrefix("Old") }.count, 2, "The first delete of pass 2 succeeded")

        // Pass 3 finally deletes cleanly: exactly one copy remains.
        page.deletePlan = .alwaysSucceed
        let result = try await client.exportMeeting(
            title: "Notes", date: nil, tags: [], markdown: newContent, transcript: nil, existingPageID: pageID,
        )
        XCTAssertTrue(result.updatedExistingPage)
        XCTAssertEqual(page.texts, texts("New", count: 5))
        XCTAssertEqual(page.creates, 0)
    }

    func testRetryAfterAFailedDeleteLeavesExactlyOneCopy() async throws {
        let page = FakeNotionPage(initial: texts("Old", count: 4))
        let client = page.makeClient(databaseID: databaseID)
        let newContent = markdown("New", count: 4)

        page.deletePlan = .succeedThenFail(successes: 1)
        await assertFails(client, markdown: newContent)
        XCTAssertTrue(page.texts.contains { $0.hasPrefix("Old") }, "The content is still duplicated after the failure")

        page.deletePlan = .alwaysSucceed
        _ = try await client.exportMeeting(
            title: "Notes", date: nil, tags: [], markdown: newContent, transcript: nil, existingPageID: pageID,
        )
        XCTAssertEqual(page.texts, texts("New", count: 4))
    }

    func testAChangedProtocolIsStillAppendedWhenTheTailDoesNotMatch() async throws {
        // Leftovers of an interrupted replace of version 1, then a retry that
        // carries version 2: the tail is not the new content, so it is written.
        let page = FakeNotionPage(initial: ["Old paragraph 5."] + texts("Version1", count: 3))
        let client = page.makeClient(databaseID: databaseID)

        _ = try await client.exportMeeting(
            title: "Notes", date: nil, tags: [], markdown: markdown("Version2", count: 3), transcript: nil,
            existingPageID: pageID,
        )
        XCTAssertEqual(page.texts, texts("Version2", count: 3))
    }

    func testAnIdenticalPageIsReplacedNotSkipped() async throws {
        // Nothing precedes the matching blocks, so nothing proves an earlier
        // attempt wrote them; a re-export still goes through the normal replace.
        let page = FakeNotionPage(initial: texts("Same", count: 3))
        let client = page.makeClient(databaseID: databaseID)

        _ = try await client.exportMeeting(
            title: "Notes", date: nil, tags: [], markdown: markdown("Same", count: 3), transcript: nil,
            existingPageID: pageID,
        )
        XCTAssertEqual(page.texts, texts("Same", count: 3))
        XCTAssertEqual(page.appends, 1)
        XCTAssertEqual(page.deleteAttempts, 3)
    }

    // MARK: - Tolerant delete loop

    func testAFailedDeleteDoesNotStopTheRemainingDeletes() async {
        let page = FakeNotionPage(initial: texts("Old", count: 4))
        let client = page.makeClient(databaseID: databaseID)
        page.deletePlan = .failBlock(containing: "Old paragraph 2.")

        do {
            _ = try await client.exportMeeting(
                title: "Notes", date: nil, tags: [], markdown: markdown("New", count: 2), transcript: nil,
                existingPageID: pageID,
            )
            XCTFail("The failed delete must be reported")
        } catch {
            XCTAssertEqual((error as? NotionClientError)?.httpStatusCode, 500)
        }
        XCTAssertEqual(page.texts, ["Old paragraph 2."] + texts("New", count: 2))
        XCTAssertEqual(page.deleteAttempts, 4, "Every old block was tried")
    }

    func testDeletesStopAfterConsecutiveFailuresSoAnOutageIsBounded() async {
        let page = FakeNotionPage(initial: texts("Old", count: 30))
        let client = page.makeClient(databaseID: databaseID)
        page.deletePlan = .succeedThenFail(successes: 0)

        await assertFails(client, markdown: markdown("New", count: 2))
        XCTAssertEqual(page.deleteAttempts, 3)
    }

    // MARK: - Helpers

    private func texts(_ prefix: String, count: Int) -> [String] {
        (1 ... count).map { "\(prefix) paragraph \($0)." }
    }

    private func assertFails(_ client: NotionClient, markdown: String, line: UInt = #line) async {
        do {
            _ = try await client.exportMeeting(
                title: "Notes", date: nil, tags: [], markdown: markdown, transcript: nil, existingPageID: pageID,
            )
            XCTFail("Expected the replace to fail", line: line)
        } catch {
            XCTAssertEqual((error as? NotionClientError)?.httpStatusCode, 500, line: line)
        }
    }
}

/// A Notion page whose root blocks are plain paragraphs, served through the
/// URL protocol below.
private final class FakeNotionPage: @unchecked Sendable {
    enum DeletePlan {
        case alwaysSucceed
        /// The first `successes` deletes of the pass work, every later one fails.
        case succeedThenFail(successes: Int)
        case failBlock(containing: String)
    }

    private struct Block {
        let id: String
        let text: String
    }

    var deletePlan = DeletePlan.alwaysSucceed {
        didSet { deletesThisPlan = 0 }
    }

    private(set) var creates = 0
    private(set) var appends = 0
    private(set) var deleteAttempts = 0
    private var deletesThisPlan = 0
    private var blocks: [Block] = []
    private var nextID = 0

    var texts: [String] {
        blocks.map(\.text)
    }

    init(initial: [String]) {
        blocks = initial.map { Block(id: newID(), text: $0) }
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func newID() -> String {
        nextID += 1
        return "block-\(nextID)"
    }

    func makeClient(databaseID: String) -> NotionClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { [weak self] request in
            self?.handle(request) ?? (HTTPURLResponse(), Data())
        }
        return NotionClient(apiKey: "test-key", databaseID: databaseID, session: URLSession(configuration: config))
    }

    private func respond(_ request: URLRequest, json: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        ) ?? HTTPURLResponse()
        return (response, Data(json.utf8))
    }

    private func handle(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        if path.contains("/databases/") {
            return respond(request, json: #"{"id":"11111111222233334444555555555555","properties":{"Name":{"type":"title"}}}"#)
        }
        if path.hasSuffix("/children") {
            return method == "GET" ? list(request) : append(request)
        }
        if method == "DELETE" { return delete(request, path: path) }
        if path.hasSuffix("/pages"), method == "POST" {
            creates += 1
            return respond(request, json: #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","url":"https://www.notion.so/page"}"#)
        }
        return respond(request, json: #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","url":"https://www.notion.so/page"}"#)
    }

    private func list(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        let objects: [[String: Any]] = blocks.map { block in
            [
                "id": block.id,
                "type": "paragraph",
                "paragraph": ["rich_text": [["type": "text", "plain_text": block.text, "text": ["content": block.text]]]],
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["results": objects, "has_more": false])) ?? Data()
        return (respond(request, json: "{}").0, data)
    }

    private func append(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        appends += 1
        let body = Self.body(of: request)
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        for child in object?["children"] as? [[String: Any]] ?? [] {
            let richText = (child["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]]
            let text = richText?.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined() ?? ""
            blocks.append(Block(id: newID(), text: text))
        }
        return respond(request, json: "{}")
    }

    private func delete(_ request: URLRequest, path: String) -> (HTTPURLResponse, Data) {
        deleteAttempts += 1
        deletesThisPlan += 1
        let id = path.components(separatedBy: "/").last ?? ""
        let fails: Bool = switch deletePlan {
        case .alwaysSucceed: false
        case let .succeedThenFail(successes): deletesThisPlan > successes
        case let .failBlock(text): blocks.first { $0.id == id }?.text == text
        }
        if fails {
            return respond(
                request,
                json: #"{"object":"error","status":500,"code":"internal_server_error","message":"boom"}"#,
                status: 500,
            )
        }
        blocks.removeAll { $0.id == id }
        return respond(request, json: "{}")
    }
}
