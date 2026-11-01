import AppKit
import Foundation
import Observation

/// The settings workflow uses a client boundary so connection and schema failures
/// can be exercised without issuing requests from a SwiftUI view.
protocol NotionSettingsClient: Sendable {
    func listDatabases() async throws -> [NotionDatabaseItem]
    func listPages() async throws -> [NotionPageItem]
    func getBotInfo() async throws -> (name: String, workspaceName: String?)
    func checkDatabaseCompatibility(id: String) async throws -> NotionDatabaseSchemaStatus
    func upgradeDatabaseSchema(id: String, missingColumns: [String]) async throws -> NotionDatabaseSchemaStatus
    func createDatabase(parentPageID: String, title: String) async throws -> String
}

extension NotionClient: NotionSettingsClient {}

/// `ObservableObject` only so `@StateObject` keeps one instance across view re-creation.
@Observable
@MainActor
final class NotionExportSettingsModel: ObservableObject {
    static let createDatabaseTag = "__create_meeting_transcriber__"
    static let customDatabaseTag = "__custom__"
    static let manualParentTag = "__manual__"

    let settings: AppSettings
    var apiKeyDraft: String
    var testingNotion = false
    var isNotionConnected = false
    var availableDatabases: [NotionDatabaseItem] = []
    var availablePages: [NotionPageItem] = []
    var selectedDatabaseTag = createDatabaseTag
    var selectedParentPageID = ""
    var manualParentPageInput = ""
    var manualDatabaseIDInput = ""
    var isCreatingDatabase = false
    var createDatabaseError: String?
    var notionStatusResult: ConnectionTestResult?
    var databaseSchemaStatus: NotionDatabaseSchemaStatus?
    var checkingSchema = false
    var upgradingSchema = false
    var schemaCheckError: String?
    private var schemaCheckToken = UUID()
    private var connectedBotName = "Meeting Transcriber"
    private var lastConnectionRefresh: Date?
    /// Observed, unlike the client factory: the notice below follows it, and a
    /// commit that changes nothing else must still redraw the notice.
    private var committedAPIKey: String
    @ObservationIgnored private let clientFactory: (String) -> any NotionSettingsClient

    init(settings: AppSettings, clientFactory: @escaping (String) -> any NotionSettingsClient = { NotionClient(apiKey: $0) }) {
        self.settings = settings
        self.clientFactory = clientFactory
        let key = settings.notionAPIKey
        apiKeyDraft = key
        committedAPIKey = key
        if !settings.notionDatabaseID.isEmpty {
            manualDatabaseIDInput = settings.notionDatabaseID
            selectedDatabaseTag = Self.customDatabaseTag
            isNotionConnected = settings.notionExportEnabled && !key.isEmpty
        }
    }

    var hasAPIKey: Bool {
        !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What an export would use: the key in the settings, not the text being typed.
    private var hasCommittedAPIKey: Bool {
        !committedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Export is on but a finished meeting would not reach Notion. The key is
    /// the committed one: a draft that was typed or erased but not yet
    /// committed (Return, focus loss) changes nothing about what exports.
    var configurationNotice: String? {
        guard settings.notionExportEnabled else { return nil }
        if !hasCommittedAPIKey { return "No API token. Meetings are not exported until you add one." }
        if settings.notionDatabaseID.isEmpty { return "No database selected. Meetings are not exported until you choose one." }
        return nil
    }

    var needsDatabaseConfirmation: Bool {
        settings.notionDatabaseID.isEmpty && selectedDatabaseTag != Self.createDatabaseTag && selectedDatabaseTag != Self.customDatabaseTag
    }

    var databaseInput: String {
        selectedDatabaseTag == Self.customDatabaseTag ? manualDatabaseIDInput : selectedDatabaseTag
    }

    var isParentPageAvailable: Bool {
        !parentPageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var parentPageInput: String {
        selectedParentPageID != Self.manualParentTag && !selectedParentPageID.isEmpty ? selectedParentPageID : manualParentPageInput
    }

    func commitAPIKey() {
        guard apiKeyDraft != committedAPIKey else { return }
        settings.notionAPIKey = apiKeyDraft
        committedAPIKey = apiKeyDraft
        isNotionConnected = false
        notionStatusResult = nil
        resetSchemaState()
    }

    /// Settings is hidden on close, so the field may receive neither a focus
    /// change nor onDisappear. Other windows closing must not commit its draft.
    func settingsWindowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow)?.identifier?.rawValue == "settings" else { return }
        commitAPIKey()
    }

    func selectDatabase(_ tag: String) {
        selectedDatabaseTag = tag
        resetSchemaState()
        // This method is called only by a deliberate picker interaction. A
        // connection refresh assigns the suggestion without writing settings.
        if tag == Self.customDatabaseTag {
            settings.notionDatabaseID = manualDatabaseIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if tag == Self.createDatabaseTag {
            settings.notionDatabaseID = ""
        } else {
            settings.notionDatabaseID = tag
        }
    }

    func confirmDatabase() {
        guard needsDatabaseConfirmation else { return }
        settings.notionDatabaseID = selectedDatabaseTag
    }

    func setManualDatabaseInput(_ value: String) {
        manualDatabaseIDInput = value
        // A half-typed ID stays a draft: an export starting now must not pick it up.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = NotionClient.extractID(from: value) {
            settings.notionDatabaseID = id
        } else if trimmed.isEmpty {
            settings.notionDatabaseID = ""
        }
        resetSchemaState()
    }

    func refreshAfterActivation() async {
        guard settings.notionExportEnabled, isNotionConnected, !testingNotion, hasAPIKey else { return }
        if let lastConnectionRefresh, Date().timeIntervalSince(lastConnectionRefresh) < 30 { return }
        await refresh(silent: true)
    }

    func refresh(silent: Bool = false) async {
        commitAPIKey()
        guard hasAPIKey, !testingNotion else { return }
        testingNotion = true
        defer { testingNotion = false }
        if !silent { notionStatusResult = nil }
        let key = committedAPIKey
        let client = clientFactory(key.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            async let databases = client.listDatabases()
            async let pages = client.listPages()
            let (fetchedDatabases, fetchedPages) = try await (databases, pages)
            let bot = try? await client.getBotInfo()
            guard key == committedAPIKey else { return }
            availableDatabases = deduplicateDatabases(fetchedDatabases)
            availablePages = fetchedPages
            connectedBotName = bot?.name ?? "Meeting Transcriber"
            // Never preselected: one click would create a database under a page nobody chose.
            if selectedParentPageID != Self.manualParentTag,
               !fetchedPages.contains(where: { $0.id == selectedParentPageID }) {
                selectedParentPageID = fetchedPages.isEmpty ? Self.manualParentTag : ""
            }
            applyDatabaseSelection()
            isNotionConnected = true
            lastConnectionRefresh = Date()
            if !silent {
                let workspace = bot?.workspaceName.map { " in workspace \"\($0)\"" } ?? ""
                notionStatusResult = .success("Connected to Notion\(workspace) (\(availableDatabases.count) databases found)")
            }
            // Programmatic picker updates have no onChange handler, so each
            // refresh checks the selected database exactly once.
            await checkDatabaseSchema(id: databaseInput)
        } catch {
            guard key == committedAPIKey else { return }
            let status = (error as? NotionClientError)?.httpStatusCode
            if status == 401 || status == 403 { isNotionConnected = false }
            notionStatusResult = .failure(silent && isNotionConnected
                ? "Could not refresh Notion. Your saved configuration is unchanged."
                : error.localizedDescription)
        }
    }

    private func applyDatabaseSelection() {
        let storedID = NotionClient.extractID(from: settings.notionDatabaseID) ?? settings.notionDatabaseID
        if !storedID.isEmpty {
            manualDatabaseIDInput = settings.notionDatabaseID
            let isListed = availableDatabases.contains { $0.id == storedID }
            selectedDatabaseTag = isListed ? storedID : Self.customDatabaseTag
        } else if let suggestion = availableDatabases.first(where: { $0.title == "Meeting Transcriber" }) {
            selectedDatabaseTag = suggestion.id
        } else {
            selectedDatabaseTag = Self.createDatabaseTag
        }
    }

    func resetSchemaState() {
        schemaCheckToken = UUID()
        databaseSchemaStatus = nil
        schemaCheckError = nil
        checkingSchema = false
        upgradingSchema = false
    }

    func checkDatabaseSchema(id: String) async {
        guard let cleanID = NotionClient.extractID(from: id) else {
            resetSchemaState()
            if !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               id != Self.createDatabaseTag, id != Self.customDatabaseTag {
                schemaCheckError = "Enter a valid Notion database URL or 32-character database ID."
            }
            return
        }
        guard hasAPIKey else {
            resetSchemaState()
            return
        }
        let token = UUID()
        schemaCheckToken = token
        checkingSchema = true
        upgradingSchema = false
        schemaCheckError = nil
        databaseSchemaStatus = nil
        let client = clientFactory(committedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let status = try await client.checkDatabaseCompatibility(id: cleanID)
            guard schemaCheckToken == token else { return }
            databaseSchemaStatus = status
            if !availableDatabases.contains(where: { $0.id == cleanID }) {
                availableDatabases.append(NotionDatabaseItem(id: cleanID, title: status.title))
            }
        } catch {
            guard schemaCheckToken == token else { return }
            schemaCheckError = schemaError(error, databaseID: cleanID)
        }
        checkingSchema = false
    }

    private func schemaError(_ error: any Error, databaseID: String) -> String {
        if let clientError = error as? NotionClientError {
            if case .databaseInTrash = clientError {
                availableDatabases.removeAll { $0.id == databaseID }
                if selectedDatabaseTag == databaseID {
                    selectedDatabaseTag = Self.customDatabaseTag
                    manualDatabaseIDInput = databaseID
                }
                return "This database is in the Notion trash. Restore it in Notion or choose another database."
            }
            if clientError.httpStatusCode == 404 {
                return "Database not found or not shared with \"\(connectedBotName)\". "
                    + "Please open it in Notion → \"...\" → \"Connect to\" → \"\(connectedBotName)\"."
            }
        }
        return "Could not access database: \(error.localizedDescription)"
    }

    func upgradeDatabaseSchema() async {
        guard let status = databaseSchemaStatus, hasAPIKey, !upgradingSchema else { return }
        upgradingSchema = true
        let token = schemaCheckToken
        let client = clientFactory(committedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let updated = try await client.upgradeDatabaseSchema(id: status.databaseID, missingColumns: status.missingColumns)
            guard schemaCheckToken == token else { return }
            databaseSchemaStatus = updated
            schemaCheckError = nil
        } catch {
            guard schemaCheckToken == token else { return }
            schemaCheckError = "Failed to update columns: \(error.localizedDescription)"
        }
        upgradingSchema = false
    }

    func createDatabase() async {
        commitAPIKey()
        guard hasAPIKey, !isCreatingDatabase else { return }
        guard let parentID = NotionClient.extractID(from: parentPageInput) else {
            createDatabaseError = "Enter a valid Notion page URL or 32-character page ID."
            return
        }
        isCreatingDatabase = true
        defer { isCreatingDatabase = false }
        createDatabaseError = nil
        let key = committedAPIKey
        let client = clientFactory(key.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let createdID = try await client.createDatabase(parentPageID: parentID, title: "Meeting Transcriber")
            guard key == committedAPIKey else { return }
            settings.notionDatabaseID = createdID
            availableDatabases = deduplicateDatabases([NotionDatabaseItem(id: createdID, title: "Meeting Transcriber")] + availableDatabases)
            selectedDatabaseTag = createdID
            await checkDatabaseSchema(id: createdID)
        } catch {
            guard key == committedAPIKey else { return }
            let mayExist = error is URLError ? " It may have been created anyway, so check Notion before trying again." : ""
            createDatabaseError = "Failed to create database: \(error.localizedDescription)\(mayExist)"
        }
    }

    private func deduplicateDatabases(_ databases: [NotionDatabaseItem]) -> [NotionDatabaseItem] {
        var seen = Set<String>()
        return databases.filter { seen.insert(NotionClient.extractID(from: $0.id) ?? $0.id.lowercased()).inserted }
    }
}
