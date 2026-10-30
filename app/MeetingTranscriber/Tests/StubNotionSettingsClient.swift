import Foundation
@testable import MeetingTranscriber

@MainActor
final class StubNotionSettingsClient: NotionSettingsClient {
    static let databaseID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let parentID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    var databases: [NotionDatabaseItem] = []
    var pages: [NotionPageItem] = []
    var connectionError: (any Error)?
    var schemaError: (any Error)?
    var createError: (any Error)?
    var suspendCreation = false
    var createContinuation: CheckedContinuation<String, any Error>?
    var upgradeError: (any Error)?
    var databaseRequests = 0
    var pageRequests = 0
    var schemaRequests: [String] = []
    var createdParents: [String] = []
    var upgradedDatabases: [String] = []
    var schema = NotionDatabaseSchemaStatus(
        databaseID: databaseID,
        title: "Meeting Transcriber",
        schema: NotionResolvedSchema(titleColumnName: "Name", dateColumnName: nil, tagsColumnName: nil),
    )

    func listDatabases() throws -> [NotionDatabaseItem] {
        databaseRequests += 1
        if let connectionError { throw connectionError }
        return databases
    }

    func listPages() throws -> [NotionPageItem] {
        pageRequests += 1
        if let connectionError { throw connectionError }
        return pages
    }

    func getBotInfo() -> (name: String, workspaceName: String?) {
        ("Test Integration", "Test Workspace")
    }

    func checkDatabaseCompatibility(id: String) throws -> NotionDatabaseSchemaStatus {
        schemaRequests.append(id)
        if let schemaError { throw schemaError }
        return schema
    }

    func upgradeDatabaseSchema(id: String, missingColumns _: [String]) throws -> NotionDatabaseSchemaStatus {
        upgradedDatabases.append(id)
        if let upgradeError { throw upgradeError }
        return NotionDatabaseSchemaStatus(
            databaseID: id, title: "Meeting Transcriber",
            schema: NotionResolvedSchema(titleColumnName: "Name", dateColumnName: "Date", tagsColumnName: "Tags"),
        )
    }

    func createDatabase(parentPageID: String, title _: String) async throws -> String {
        createdParents.append(parentPageID)
        if suspendCreation {
            return try await withCheckedThrowingContinuation { createContinuation = $0 }
        }
        if let createError { throw createError }
        return Self.databaseID
    }
}
