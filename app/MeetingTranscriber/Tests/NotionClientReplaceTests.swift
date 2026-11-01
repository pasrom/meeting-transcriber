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
        let result = try await export(client, markdown: newContent)
        XCTAssertTrue(result.updatedExistingPage)
        XCTAssertEqual(page.texts, texts("New", count: 5))
        XCTAssertEqual(page.creates, 0)
    }

    func testInterruptedReplaceOfARealProtocolConvergesWithoutGrowth() async throws {
        // A protocol as the app saves it ends in toggles that carry the full
        // transcript as children, and has a table: the shapes whose content a
        // listing of root blocks cannot show. The recognition must still work
        // for them, or it would not help the protocols users actually export.
        let protocolMarkdown = """
        # Weekly Sync

        ## Summary

        - Alice presented the plan.
        - Bob raised a risk.

        | Owner | Task |
        | --- | --- |
        | Alice | Draft |

        ---

        ## Full Transcript

        Alice: Hello.
        Bob: Hi.
        """
        let expected = MarkdownToNotionBlocks.convert(markdown: protocolMarkdown, transcript: nil)
        XCTAssertEqual(expected.last?.type, "toggle", "The fixture must end in a transcript toggle")
        XCTAssertTrue(expected.contains { $0.type == "table" })
        let page = FakeNotionPage(initial: texts("Old", count: 4))
        let client = page.makeClient(databaseID: databaseID)

        page.deletePlan = .succeedThenFail(successes: 1)
        await assertFails(client, markdown: protocolMarkdown)
        let sizeAfterFirstFailure = page.texts.count

        page.deletePlan = .succeedThenFail(successes: 0)
        await assertFails(client, markdown: protocolMarkdown)
        XCTAssertLessThanOrEqual(page.texts.count, sizeAfterFirstFailure, "A failed replace must not make the page grow")
        XCTAssertEqual(page.appends, 1, "Only the first pass wrote the protocol")

        page.deletePlan = .alwaysSucceed
        _ = try await export(client, markdown: protocolMarkdown)
        XCTAssertEqual(page.types, expected.map(\.type))
        XCTAssertEqual(page.appends, 1)
    }

    func testAHeadingIsNotTakenForAParagraphWithTheSameText() async throws {
        // Text equal, types differ: the new content must still be written.
        let page = FakeNotionPage(initial: [
            .init(type: "paragraph", text: "Old"),
            .init(type: "heading_1", text: "Alpha"),
            .init(type: "paragraph", text: "Beta"),
        ])
        let client = page.makeClient(databaseID: databaseID)

        _ = try await export(client, markdown: "Alpha\n\nBeta")
        XCTAssertEqual(page.texts, ["Alpha", "Beta"])
        XCTAssertEqual(page.types, ["paragraph", "paragraph"])
        XCTAssertEqual(page.appends, 1)
    }

    func testAChangedProtocolIsStillAppendedWhenTheTailDoesNotMatch() async throws {
        // Leftovers of an interrupted replace of version 1, then a retry that
        // carries version 2: the tail is not the new content, so it is written.
        let page = FakeNotionPage(initial: ["Old paragraph 5."] + texts("Version1", count: 3))
        let client = page.makeClient(databaseID: databaseID)

        _ = try await export(client, markdown: markdown("Version2", count: 3))
        XCTAssertEqual(page.texts, texts("Version2", count: 3))
    }

    func testAnIdenticalPageIsReplacedNotSkipped() async throws {
        // Nothing precedes the matching blocks, so nothing proves an earlier
        // attempt wrote them; a re-export still goes through the normal replace.
        let page = FakeNotionPage(initial: texts("Same", count: 3))
        let client = page.makeClient(databaseID: databaseID)

        _ = try await export(client, markdown: markdown("Same", count: 3))
        XCTAssertEqual(page.texts, texts("Same", count: 3))
        XCTAssertEqual(page.appends, 1)
        XCTAssertEqual(page.deleteAttempts, 3)
    }

    // MARK: - Blocks the export did not write

    func testAReplaceKeepsBlocksTheUserAddedUnderThePage() async throws {
        // Notion lists a sub-page, an inline database or an image added under
        // the page as one of its root blocks. No protocol produces them, so
        // they are the user's, and a replace must not delete them.
        let page = FakeNotionPage(initial: [
            .init(type: "paragraph", text: "Old paragraph 1."),
            .init(type: "child_page", text: ""),
            .init(type: "paragraph", text: "Old paragraph 2."),
            .init(type: "child_database", text: ""),
            .init(type: "image", text: ""),
        ])
        let client = page.makeClient(databaseID: databaseID)

        _ = try await export(client, markdown: markdown("New", count: 2))
        XCTAssertEqual(page.types, ["child_page", "child_database", "image", "paragraph", "paragraph"])
        XCTAssertEqual(page.texts.filter { !$0.isEmpty }, texts("New", count: 2))
        XCTAssertEqual(page.deleteAttempts, 2, "Only the old export blocks are deleted")
    }

    func testAChildPageAfterTheCopyDoesNotHideAnInterruptedReplace() async throws {
        // Leftovers, the complete copy, then a sub-page the user added: the
        // sub-page is not part of the comparison, so the copy is still
        // recognised and not appended a second time.
        let page = FakeNotionPage(
            initial: [.init(type: "paragraph", text: "Old paragraph 1.")]
                + texts("New", count: 2).map { .init(type: "paragraph", text: $0) }
                + [.init(type: "child_page", text: "")],
        )
        let client = page.makeClient(databaseID: databaseID)

        _ = try await export(client, markdown: markdown("New", count: 2))
        XCTAssertEqual(page.appends, 0)
        XCTAssertEqual(page.types, ["paragraph", "paragraph", "child_page"])
        XCTAssertEqual(page.texts.filter { !$0.isEmpty }, texts("New", count: 2))
    }

    // MARK: - Tolerant delete loop

    func testAFailedDeleteDoesNotStopTheRemainingDeletes() async {
        let page = FakeNotionPage(initial: texts("Old", count: 4))
        let client = page.makeClient(databaseID: databaseID)
        page.deletePlan = .failBlocks(containing: ["Old paragraph 2."])

        do {
            _ = try await export(client, markdown: markdown("New", count: 2))
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

    func testSuccessfulDeleteResetsTheConsecutiveFailureCount() async {
        // Failures on blocks 1, 3 and 4 are never three in a row, so every
        // block is tried and only the three that failed remain.
        let page = FakeNotionPage(initial: texts("Old", count: 6))
        let client = page.makeClient(databaseID: databaseID)
        page.deletePlan = .failBlocks(containing: ["Old paragraph 1.", "Old paragraph 3.", "Old paragraph 4."])

        await assertFails(client, markdown: markdown("New", count: 2))
        XCTAssertEqual(page.deleteAttempts, 6, "A success between failures keeps the loop going")
        XCTAssertEqual(page.texts, ["Old paragraph 1.", "Old paragraph 3.", "Old paragraph 4."] + texts("New", count: 2))
    }

    func testADeleteOfABlockThatIsAlreadyGoneCountsAsDone() async throws {
        // Three 404s in a row: neither a failure of the export nor a run of
        // failures that ends the loop, so the blocks after them still go. One
        // listing after the loop confirms they are gone.
        let page = FakeNotionPage(initial: texts("Old", count: 5))
        let client = page.makeClient(databaseID: databaseID)
        page.deletePlan = .goneBlocks(containing: ["Old paragraph 1.", "Old paragraph 2.", "Old paragraph 3."])

        let result = try await export(client, markdown: markdown("New", count: 2))
        XCTAssertTrue(result.updatedExistingPage)
        XCTAssertEqual(page.deleteAttempts, 5)
        XCTAssertEqual(page.listCalls, 2, "The plan's listing and the confirming one")
        XCTAssertEqual(page.texts, texts("New", count: 2))
    }

    func testA404ForABlockThatIsStillThereFailsTheExport() async {
        // Lost access answers 404 too, while the block stays on the page: the
        // confirming listing still shows it, so the export must not report success.
        let page = FakeNotionPage(initial: texts("Old", count: 3))
        let client = page.makeClient(databaseID: databaseID)
        page.deletePlan = .hiddenBlocks(containing: ["Old paragraph 2."])

        do {
            _ = try await export(client, markdown: markdown("New", count: 2))
            XCTFail("A 404 for a block that is still listed must fail the export")
        } catch {
            XCTAssertEqual((error as? NotionClientError)?.httpStatusCode, 404)
        }
        XCTAssertEqual(page.deleteAttempts, 3)
        XCTAssertEqual(page.texts, ["Old paragraph 2."] + texts("New", count: 2))
    }

    func testA404DoesNotResetTheRunOfFailures() async {
        // Failures with 404s between them are still a run: the outage bound holds.
        let page = FakeNotionPage(initial: texts("Old", count: 8))
        let client = page.makeClient(databaseID: databaseID)
        page.deletePlan = .alternateFailAndGone

        await assertFails(client, markdown: markdown("New", count: 2))
        XCTAssertEqual(page.deleteAttempts, 5, "fail, 404, fail, 404, fail ends the loop")
    }

    // MARK: - Listing more than one page of root blocks

    func testEveryRootBlockOfALongPageIsReplaced() async throws {
        let page = FakeNotionPage(initial: texts("Old", count: 150))
        let client = page.makeClient(databaseID: databaseID)

        _ = try await export(client, markdown: markdown("New", count: 3))
        XCTAssertEqual(page.listCalls, 2)
        XCTAssertEqual(page.deleteAttempts, 150)
        XCTAssertEqual(page.texts, texts("New", count: 3))
    }

    func testACompleteCopyIsRecognisedWhenTheListingNeedsSeveralPages() async throws {
        // 98 leftovers then the copy: its last block is the 101st, so the copy
        // is split across the first two listing pages and only seen whole when
        // every page is read.
        let page = FakeNotionPage(initial: texts("Old", count: 98) + texts("New", count: 3))
        let client = page.makeClient(databaseID: databaseID)

        _ = try await export(client, markdown: markdown("New", count: 3))
        XCTAssertEqual(page.appends, 0)
        XCTAssertEqual(page.deleteAttempts, 98)
        XCTAssertEqual(page.texts, texts("New", count: 3))
    }

    // MARK: - Helpers

    private func texts(_ prefix: String, count: Int) -> [String] {
        (1 ... count).map { "\(prefix) paragraph \($0)." }
    }

    @discardableResult
    private func export(_ client: NotionClient, markdown: String) async throws -> NotionPageResult {
        try await client.exportMeeting(
            title: "Notes", date: nil, tags: [], markdown: markdown, transcript: nil, existingPageID: pageID,
        )
    }

    private func assertFails(_ client: NotionClient, markdown: String, line: UInt = #line) async {
        do {
            _ = try await export(client, markdown: markdown)
            XCTFail("Expected the replace to fail", line: line)
        } catch {
            XCTAssertEqual((error as? NotionClientError)?.httpStatusCode, 500, line: line)
        }
    }
}

/// A Notion page with root blocks of any type, served through `MockURLProtocol`.
/// The block listing pages through 100 blocks at a time, as Notion does.
private final class FakeNotionPage: @unchecked Sendable {
    enum DeletePlan {
        case alwaysSucceed
        /// The first `successes` deletes of the pass work, every later one fails.
        case succeedThenFail(successes: Int)
        case failBlocks(containing: Set<String>)
        /// Blocks with these texts vanish before their delete, which then answers 404.
        case goneBlocks(containing: Set<String>)
        /// Deletes of blocks with these texts answer 404 while the blocks stay, as with lost access.
        case hiddenBlocks(containing: Set<String>)
        /// Odd deletes of the pass fail with 500, even ones answer 404 for a block that is gone.
        case alternateFailAndGone
    }

    struct Seed {
        let type: String
        let text: String
    }

    private struct Block {
        let id: String
        let type: String
        let text: String
    }

    private static let listPageSize = 100

    var deletePlan = DeletePlan.alwaysSucceed {
        didSet { deletesThisPlan = 0 }
    }

    private(set) var creates = 0
    private(set) var appends = 0
    private(set) var deleteAttempts = 0
    private(set) var listCalls = 0
    private var deletesThisPlan = 0
    private var blocks: [Block] = []
    private var nextID = 0

    var texts: [String] {
        blocks.map(\.text)
    }

    var types: [String] {
        blocks.map(\.type)
    }

    init(initial: [Seed]) {
        blocks = initial.map { Block(id: newID(), type: $0.type, text: $0.text) }
    }

    convenience init(initial: [String]) {
        self.init(initial: initial.map { Seed(type: "paragraph", text: $0) })
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
        listCalls += 1
        let cursor = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "start_cursor" }?.value.flatMap(Int.init) ?? 0
        let end = min(cursor + Self.listPageSize, blocks.count)
        let objects: [[String: Any]] = blocks[cursor ..< end].map { block in
            [
                "id": block.id,
                "type": block.type,
                block.type: ["rich_text": [["type": "text", "plain_text": block.text, "text": ["content": block.text]]]],
            ]
        }
        var payload: [String: Any] = ["results": objects, "has_more": end < blocks.count]
        if end < blocks.count { payload["next_cursor"] = String(end) }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return (respond(request, json: "{}").0, data)
    }

    private func append(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        appends += 1
        let body = Self.body(of: request)
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        for child in object?["children"] as? [[String: Any]] ?? [] {
            let type = child["type"] as? String ?? ""
            let content = child[type] as? [String: Any]
            let richText = content?["rich_text"] as? [[String: Any]]
            let text = richText?.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined() ?? ""
            blocks.append(Block(id: newID(), type: type, text: text))
        }
        return respond(request, json: "{}")
    }

    private func delete(_ request: URLRequest, path: String) -> (HTTPURLResponse, Data) {
        deleteAttempts += 1
        deletesThisPlan += 1
        let id = path.components(separatedBy: "/").last ?? ""
        let text = blocks.first { $0.id == id }?.text
        let status = switch deletePlan {
        case .alwaysSucceed: 200
        case let .succeedThenFail(successes): deletesThisPlan > successes ? 500 : 200
        case let .failBlocks(texts): text.map(texts.contains) == true ? 500 : 200
        case let .goneBlocks(texts), let .hiddenBlocks(texts): text.map(texts.contains) == true ? 404 : 200
        case .alternateFailAndGone: deletesThisPlan.isMultiple(of: 2) ? 404 : 500
        }
        // A gone block has vanished before its delete arrives, as Notion would see it.
        let vanishes = switch deletePlan {
        case .hiddenBlocks: status == 200
        default: status != 500
        }
        if vanishes { blocks.removeAll { $0.id == id } }
        guard status == 200 else {
            return respond(request, json: #"{"object":"error","status":\#(status),"message":"boom"}"#, status: status)
        }
        return respond(request, json: "{}")
    }
}
