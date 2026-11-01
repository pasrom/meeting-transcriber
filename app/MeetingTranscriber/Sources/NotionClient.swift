import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber", category: "NotionClient")

/// Native async Notion API client for creating databases and exporting meeting notes.
actor NotionClient: NotionExporting {
    // Keep database IDs and schemas on the legacy API deliberately. Databases
    // with multiple data sources require 2025-09-03 and are rejected by Notion;
    // never guess which data source should receive the meeting.
    // https://developers.notion.com/docs/upgrade-guide-2025-09-03
    static let notionAPIVersion = "2022-06-28"
    private static let baseURL = URL(string: "https://api.notion.com/v1")!
    private static let maxSearchPages = 20
    private static let pageSize = 100
    private static let maxRateLimitRetries = 3

    private let apiKey: String
    private let configuredDatabaseID: String?
    private let session: URLSession

    init(apiKey: String, databaseID: String? = nil, session: URLSession? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredDatabaseID = databaseID.flatMap { NotionClient.extractID(from: $0) }
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            // Generous for the page create, 100 blocks on a slow uplink: giving
            // up on a request Notion may still complete can leave a duplicate.
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - ID Parser

    /// Extracts a 32-hex character Notion ID from a raw UUID or Notion page/database URL.
    static func extractID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Remove query parameters and anchors
        let withoutQuery = trimmed.components(separatedBy: "?").first ?? trimmed
        let path = withoutQuery.components(separatedBy: "#").first ?? withoutQuery

        // 1. Standard UUID format: 8-4-4-4-12
        let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        if let uuidRegex = try? NSRegularExpression(pattern: uuidPattern),
           let match = uuidRegex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           let range = Range(match.range, in: path) {
            return String(path[range]).replacingOccurrences(of: "-", with: "").lowercased()
        }

        // 2. Continuous 32-hex characters
        let hexPattern = #"[0-9a-fA-F]{32}"#
        if let hexRegex = try? NSRegularExpression(pattern: hexPattern),
           let match = hexRegex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           let range = Range(match.range, in: path) {
            return String(path[range]).lowercased()
        }

        return nil
    }

    // MARK: - Database Management

    /// Retrieves the current bot user and workspace name.
    func getBotInfo() async throws -> (name: String, workspaceName: String?) {
        let decoded: NotionBotInfoResponse = try await perform("GET", path: "users/me")
        return (decoded.name ?? "Integration", decoded.bot?.workspaceName)
    }

    /// Checks the database schema and reports column compatibility.
    func checkDatabaseCompatibility(id: String) async throws -> NotionDatabaseSchemaStatus {
        let database = try await fetchDatabase(id: id)
        return NotionDatabaseSchemaStatus(
            databaseID: database.id,
            title: database.title,
            schema: database.schema,
        )
    }

    /// Adds missing required columns to the database schema.
    func upgradeDatabaseSchema(id: String, missingColumns: [String]) async throws -> NotionDatabaseSchemaStatus {
        let database = try await fetchDatabase(id: id)
        let columns = NotionColumnDefinition.definitions(
            for: missingColumns,
            existingProperties: database.properties,
        )
        guard !columns.isEmpty else {
            return NotionDatabaseSchemaStatus(
                databaseID: database.id,
                title: database.title,
                schema: database.schema,
            )
        }

        let properties = try await addColumns(columns, to: database.id)
        guard !properties.isEmpty else {
            return try await checkDatabaseCompatibility(id: database.id)
        }
        return NotionDatabaseSchemaStatus(
            databaseID: database.id,
            title: database.title,
            schema: NotionResolvedSchema.resolve(properties),
        )
    }

    /// Creates a new "Meeting Transcriber" database under the specified parent page.
    func createDatabase(parentPageID: String, title: String = "Meeting Transcriber") async throws -> String {
        guard let cleanParentID = Self.extractID(from: parentPageID) else {
            throw NotionClientError.invalidID("Invalid Parent Page ID or URL")
        }

        let payload = NotionDatabaseCreateRequest(
            parent: .init(pageId: cleanParentID),
            title: [.init(text: .init(content: title))],
            properties: .init(),
        )
        let decoded: NotionDatabaseResponse = try await perform(
            "POST", path: "databases", body: JSONEncoder().encode(payload),
        )
        return decoded.id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private struct FetchedDatabase {
        let id: String
        let title: String
        let properties: [String: NotionDatabaseResponse.PropertyInfo]
        let schema: NotionResolvedSchema
    }

    /// Reads the database once and resolves its columns, so the compatibility
    /// check and the exporter cannot disagree about which property is used.
    private func fetchDatabase(id: String) async throws -> FetchedDatabase {
        guard let cleanID = Self.extractID(from: id) else {
            throw NotionClientError.invalidID("Invalid Database ID or URL")
        }

        let decoded: NotionDatabaseResponse = try await perform("GET", path: "databases/\(cleanID)")
        guard !decoded.isTrashed else {
            throw NotionClientError.databaseInTrash
        }
        let titleText = decoded.title?.compactMap(\.plainText).joined() ?? ""
        let properties = decoded.properties ?? [:]
        guard properties.values.contains(where: { $0.type == "title" }) else {
            throw NotionClientError.missingTitleProperty
        }

        return FetchedDatabase(
            id: cleanID,
            title: titleText.isEmpty ? "Untitled Database" : titleText,
            properties: properties,
            schema: NotionResolvedSchema.resolve(properties),
        )
    }

    private func addColumns(
        _ columns: [NotionColumnDefinition],
        to cleanID: String,
    ) async throws -> [String: NotionDatabaseResponse.PropertyInfo] {
        let decoded: NotionDatabaseResponse = try await perform(
            "PATCH", path: "databases/\(cleanID)", body: JSONEncoder().encode(NotionDatabasePatchRequest(columns: columns)),
        )
        return decoded.properties ?? [:]
    }

    // MARK: - Search & Listing

    private func searchObjects(filterType: String) async throws -> [NotionSearchItem] {
        var results: [NotionSearchItem] = []
        var cursor: String?
        var hasMore = false
        var pageCount = 0

        repeat {
            var payload: [String: AnyEncodable] = [
                "page_size": AnyEncodable(Self.pageSize),
                "filter": AnyEncodable(["property": AnyEncodable("object"), "value": AnyEncodable(filterType)]),
            ]
            if let cursor {
                payload["start_cursor"] = AnyEncodable(cursor)
            }
            let decoded: NotionSearchResponse = try await perform(
                "POST", path: "search", body: JSONEncoder().encode(payload),
            )
            results.append(contentsOf: decoded.results)
            hasMore = decoded.hasMore
            cursor = decoded.nextCursor
            pageCount += 1
        } while hasMore && cursor != nil && pageCount < Self.maxSearchPages

        return results
    }

    /// Searches accessible databases shared with the integration.
    func listDatabases() async throws -> [NotionDatabaseItem] {
        let results = try await searchObjects(filterType: "database")

        return results
            .filter { !$0.isTrashed }
            .compactMap { item in
                let titleText = item.title?.compactMap(\.plainText).joined() ?? ""
                let cleanTitle = titleText.isEmpty ? "Untitled Database" : titleText
                let cleanID = item.id.replacingOccurrences(of: "-", with: "").lowercased()
                return NotionDatabaseItem(id: cleanID, title: cleanTitle)
            }
    }

    /// Searches accessible pages shared with the integration.
    func listPages() async throws -> [NotionPageItem] {
        let results = try await searchObjects(filterType: "page")

        return results
            .filter { !$0.isTrashed }
            .compactMap { item in
                var pageTitle = ""
                if let props = item.properties {
                    for (_, prop) in props where prop.type == "title" {
                        pageTitle = prop.title?.compactMap(\.plainText).joined() ?? ""
                        break
                    }
                }
                let cleanTitle = pageTitle.isEmpty ? "Untitled Page" : pageTitle
                let cleanID = item.id.replacingOccurrences(of: "-", with: "").lowercased()
                return NotionPageItem(id: cleanID, title: cleanTitle)
            }
    }

    // MARK: - NotionExporting

    func exportMeeting(
        title: String,
        date: Date?,
        tags: [String],
        markdown: String,
        transcript: String?,
        existingPageID: String? = nil,
        onPageCreated: @escaping @Sendable (NotionPageResult) async -> Void = { _ in },
    ) async throws -> NotionPageResult {
        guard let databaseID = configuredDatabaseID else {
            throw NotionClientError.missingDatabaseID
        }

        let database = try await fetchDatabase(id: databaseID)
        let schema = database.schema
        let properties = pageProperties(title: title, date: date, tags: tags, schema: schema)
        let blocks = MarkdownToNotionBlocks.convert(markdown: markdown, transcript: transcript)
        let omitted = omittedProperties(date: date, tags: tags, schema: schema)

        if let existingPageID,
           let cleanPageID = Self.extractID(from: existingPageID),
           let recovered = try await recoverExistingPage(
               cleanPageID,
               properties: properties,
               blocks: blocks,
               omittedProperties: omitted,
           ) {
            return recovered
        }

        return try await createPage(
            databaseID: databaseID,
            properties: properties,
            blocks: blocks,
            omittedProperties: omitted,
            onPageCreated: onPageCreated,
        )
    }

    /// Replace the job's page with the current protocol, including on a retry
    /// of a partially appended export. Append first: a failed append must not
    /// erase the previous protocol. A failure can temporarily leave duplicates;
    /// the next successful retry removes all old and partial root blocks.
    /// Re-export replaces manual edits on this app-owned page as well.
    private func recoverExistingPage(
        _ pageID: String,
        properties: [String: NotionPropertyValue],
        blocks: [NotionBlock],
        omittedProperties: [String],
    ) async throws -> NotionPageResult? {
        let existing: NotionPageResponse
        do {
            existing = try await perform("GET", path: "pages/\(pageID)")
        } catch let error as NotionClientError where error.httpStatusCode == 404 {
            return nil
        }
        guard !existing.isTrashed else { return nil }

        let oldBlockIDs = try await childBlockIDs(pageID)
        let page = try await updatePage(pageID, properties: properties)
        try await appendBlocks(blocks, to: pageID)
        for blockID in oldBlockIDs {
            _ = try await performData("DELETE", path: "blocks/\(blockID)")
        }
        return NotionPageResult(
            pageID: pageID,
            url: page.url,
            omittedProperties: omittedProperties,
            updatedExistingPage: true,
        )
    }

    private func childBlockIDs(_ pageID: String) async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "page_size", value: String(Self.pageSize))]
            if let cursor { query.append(URLQueryItem(name: "start_cursor", value: cursor)) }
            let page: NotionBlockListResponse = try await perform(
                "GET", path: "blocks/\(pageID)/children", query: query,
            )
            ids += page.results.map(\.id)
            guard page.hasMore else { break }
            guard let next = page.nextCursor, next != cursor else {
                throw NotionClientError.invalidResponse
            }
            cursor = next
        } while true
        return ids
    }

    private func updatePage(
        _ pageID: String,
        properties: [String: NotionPropertyValue],
    ) async throws -> NotionPageResponse {
        try await perform(
            "PATCH", path: "pages/\(pageID)", body: JSONEncoder().encode(NotionPageUpdateRequest(properties: properties)),
        )
    }

    private func pageProperties(
        title: String,
        date: Date?,
        tags: [String],
        schema: NotionResolvedSchema,
    ) -> [String: NotionPropertyValue] {
        // A blank title is rejected by Notion, so an unnamed import still gets
        // a usable page.
        let pageTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Meeting"
            : title
        var properties: [String: NotionPropertyValue] = [
            schema.titleColumnName: .title(pageTitle),
        ]
        if let date, let dateColumnName = schema.dateColumnName {
            properties[dateColumnName] = .date(date)
        }
        if let tagsColumnName = schema.tagsColumnName, !tags.isEmpty {
            properties[tagsColumnName] = .multiSelect(tags)
        }
        return properties
    }

    private func omittedProperties(
        date: Date?,
        tags: [String],
        schema: NotionResolvedSchema,
    ) -> [String] {
        var omitted: [String] = []
        if date != nil, schema.dateColumnName == nil { omitted.append("Date") }
        if !tags.isEmpty, schema.tagsColumnName == nil { omitted.append("Tags") }
        return omitted
    }

    private func createPage(
        databaseID: String,
        properties: [String: NotionPropertyValue],
        blocks: [NotionBlock],
        omittedProperties: [String],
        onPageCreated: @Sendable (NotionPageResult) async -> Void,
    ) async throws -> NotionPageResult {
        let batches = try NotionRequestBatches.split(blocks)
        let firstBatch = batches.first ?? []
        let remainingBlocks = Array(batches.dropFirst().joined())

        let createPayload = NotionPageCreateRequest(
            parent: .init(databaseId: databaseID),
            icon: .init(emoji: "🎙️"),
            properties: properties,
            children: firstBatch,
        )
        let page: NotionPageResponse = try await perform("POST", path: "pages", body: JSONEncoder().encode(createPayload))
        let result = NotionPageResult(
            pageID: page.id,
            url: page.url,
            omittedProperties: omittedProperties,
        )
        // Record the page before appending overflow blocks: an append failure
        // then leaves a page ID the next retry can finish instead of a second
        // page.
        await onPageCreated(result)
        try await appendBlocks(remainingBlocks, to: page.id)
        return result
    }

    private func appendBlocks(_ blocks: [NotionBlock], to pageID: String) async throws {
        for batch in try NotionRequestBatches.split(blocks) {
            _ = try await performData(
                "PATCH", path: "blocks/\(pageID)/children", body: JSONEncoder().encode(NotionBlockAppendRequest(children: batch)),
            )
        }
    }

    // MARK: - Private Helpers

    private func perform<T: Decodable>(
        _ method: String,
        path: String,
        body: Data? = nil,
        query: [URLQueryItem] = [],
    ) async throws -> T {
        let data = try await performData(method, path: path, body: body, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func performData(
        _ method: String,
        path: String,
        body: Data? = nil,
        query: [URLQueryItem] = [],
    ) async throws -> Data {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw NotionClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        applyHeaders(to: &request)
        let (data, response) = try await send(request)
        try validateResponse(response, data: data)
        return data
    }

    /// Sends one request, retrying only Notion's rate-limit response. 5xx is
    /// deliberately not retried: a lost POST response may still have created a
    /// page, and the page ID recorded by `onPageCreated` is the safe retry
    /// path. A 429 means the request was rejected, so replaying it is safe.
    /// A create that times out has no ID to record, and Notion has no idempotency
    /// key, so its retry can still produce a second page: accepted and documented
    /// in `SettingsHelp.notionExport`.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 429,
                  attempt < Self.maxRateLimitRetries else {
                return (data, response)
            }

            let delay = Self.retryDelay(response: http, attempt: attempt)
            logger.info("Notion rate limited; retrying in \(delay, privacy: .public)s")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            attempt += 1
        }
    }

    private static func retryDelay(response: HTTPURLResponse, attempt: Int) -> Double {
        if let value = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(value), seconds.isFinite {
            return min(max(seconds, 0.5), 30)
        }
        return min(0.5 * pow(2, Double(attempt)), 8)
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionClientError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = try? JSONDecoder().decode(NotionAPIErrorBody.self, from: data)
            let message = body?.message ?? String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NotionClientError.httpError(statusCode: httpResponse.statusCode, code: body?.code, message: message)
        }
    }
}

enum NotionClientError: LocalizedError, Equatable {
    case invalidID(String)
    case missingDatabaseID
    case missingTitleProperty
    case databaseInTrash
    case invalidResponse
    case httpError(statusCode: Int, code: String? = nil, message: String)

    var httpStatusCode: Int? {
        guard case let .httpError(status, _, _) = self else { return nil }
        return status
    }

    /// A short cause for the job warning. Fixed categories rather than the
    /// response text, which can quote meeting content back.
    static func exportFailureReason(for error: any Error) -> String {
        switch error {
        case let error as Self:
            error.exportFailureReason

        case let error as URLError where error.code == .timedOut:
            "request timed out"

        case is URLError:
            "network error"

        case is CancellationError:
            "cancelled"

        case is NotionExportDeadlineExceeded:
            "time limit reached"

        default:
            "unexpected response from Notion"
        }
    }

    private var exportFailureReason: String {
        switch self {
        case .invalidID, .missingDatabaseID:
            "invalid database ID"

        case .missingTitleProperty:
            "database has no title column"

        case .databaseInTrash:
            "database is in the trash"

        case .invalidResponse:
            "unexpected response from Notion"

        case let .httpError(status, _, _):
            switch status {
            case 401: "invalid API token"
            case 403: "integration lacks permission"
            case 404: "not shared with the integration"
            case 429: "rate limited by Notion"
            case 500...: "Notion server error, HTTP \(status)"
            default: "rejected by Notion, HTTP \(status)"
            }
        }
    }

    var errorDescription: String? {
        switch self {
        case let .invalidID(msg):
            msg

        case .missingDatabaseID:
            "No Notion Database ID configured."

        case .missingTitleProperty:
            "This Notion database has no title column, so a page cannot be created in it."

        case .databaseInTrash:
            "This Notion database is in the trash. Restore it in Notion or choose another database."

        case .invalidResponse:
            "Invalid response received from Notion."

        case let .httpError(status, _, msg):
            "Notion error (HTTP \(status)): \(msg)"
        }
    }
}
