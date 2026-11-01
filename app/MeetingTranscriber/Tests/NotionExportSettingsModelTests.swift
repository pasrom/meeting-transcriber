import AppKit
@testable import MeetingTranscriber
import XCTest

@MainActor
final class NotionExportSettingsModelTests: XCTestCase {
    func testRefreshSuggestsAnExactTitleWithoutSavingDestinationAndChecksSchemaOnce() async {
        let (settings, client, model) = makeModel()
        client.databases = [
            NotionDatabaseItem(id: "cccccccccccccccccccccccccccccccc", title: "Meeting Transcriber old backup"),
            NotionDatabaseItem(id: StubNotionSettingsClient.databaseID, title: "Meeting Transcriber"),
        ]

        await model.refresh()

        XCTAssertTrue(model.isNotionConnected)
        XCTAssertEqual(settings.notionDatabaseID, "")
        XCTAssertEqual(model.selectedDatabaseTag, StubNotionSettingsClient.databaseID)
        XCTAssertTrue(model.needsDatabaseConfirmation)
        XCTAssertEqual(client.schemaRequests, [StubNotionSettingsClient.databaseID])
        model.confirmDatabase()
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.databaseID)
    }

    func testRefreshDoesNotSuggestADatabaseBySubstring() async {
        let (settings, client, model) = makeModel()
        client.databases = [NotionDatabaseItem(id: StubNotionSettingsClient.databaseID, title: "Meeting Transcriber old backup")]
        await model.refresh()
        XCTAssertEqual(model.selectedDatabaseTag, NotionExportSettingsModel.createDatabaseTag)
        XCTAssertEqual(settings.notionDatabaseID, "")
        XCTAssertTrue(client.schemaRequests.isEmpty)
    }

    func testSilentTransientRefreshKeepsConnectionAndSavedConfiguration() async {
        let (settings, client, model) = makeModel(databaseID: StubNotionSettingsClient.databaseID)
        await model.refresh()
        client.connectionError = URLError(.timedOut)

        await model.refresh(silent: true)

        XCTAssertTrue(model.isNotionConnected)
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.databaseID)
        guard case let .failure(message) = model.notionStatusResult else {
            XCTFail("Expected refresh notice")
            return
        }
        XCTAssertTrue(message.contains("unchanged"))
    }

    func testAuthenticationFailureDisconnectsWithoutErasingDestination() async {
        let (settings, client, model) = makeModel(databaseID: StubNotionSettingsClient.databaseID)
        client.connectionError = NotionClientError.httpError(statusCode: 401, message: "Unauthorized")
        await model.refresh(silent: true)
        XCTAssertFalse(model.isNotionConnected)
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.databaseID)
        XCTAssertFalse(model.testingNotion)
    }

    func testRealAPI404ShowsTheSharingHint() async {
        let (_, client, model) = makeModel()
        client.schemaError = NotionClientError.httpError(statusCode: 404, code: "object_not_found", message: "Not found")
        await model.checkDatabaseSchema(id: StubNotionSettingsClient.databaseID)
        XCTAssertEqual(model.schemaCheckError?.contains("not found or not shared"), true)
        XCTAssertFalse(model.checkingSchema)
    }

    func testTrashedDatabaseIsRemovedWithoutErasingSavedDestination() async {
        let (settings, client, model) = makeModel(databaseID: StubNotionSettingsClient.databaseID)
        model.availableDatabases = [NotionDatabaseItem(id: StubNotionSettingsClient.databaseID, title: "Trashed")]
        model.selectedDatabaseTag = StubNotionSettingsClient.databaseID
        client.schemaError = NotionClientError.databaseInTrash
        await model.checkDatabaseSchema(id: StubNotionSettingsClient.databaseID)
        XCTAssertTrue(model.availableDatabases.isEmpty)
        XCTAssertEqual(model.selectedDatabaseTag, NotionExportSettingsModel.customDatabaseTag)
        XCTAssertFalse(model.needsDatabaseConfirmation)
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.databaseID)
        XCTAssertEqual(model.schemaCheckError?.contains("trash"), true)
    }

    func testNoTokenNoticeFollowsTheCommittedKeyNotTheTypedDraft() {
        let (settings, _, _) = makeModel(databaseID: StubNotionSettingsClient.databaseID)
        settings.notionAPIKey = ""
        let unsaved = NotionExportSettingsModel(settings: settings) { _ in StubNotionSettingsClient() }
        XCTAssertEqual(unsaved.configurationNotice, "No API token. Meetings are not exported until you add one.")

        unsaved.apiKeyDraft = "ntn_typed"
        XCTAssertNotNil(unsaved.configurationNotice, "typed but not committed: the export still has no usable key")

        unsaved.commitAPIKey()
        XCTAssertNil(unsaved.configurationNotice)

        unsaved.apiKeyDraft = ""
        XCTAssertNil(unsaved.configurationNotice, "erased but not committed: the saved key still exports")
    }

    func testCreationRejectsInvalidParentAndReportsFailureWithoutChangingDestination() async {
        let (settings, client, model) = makeModel()
        model.manualParentPageInput = "invalid"
        await model.createDatabase()
        XCTAssertTrue(client.createdParents.isEmpty)
        XCTAssertNotNil(model.createDatabaseError)
        model.manualParentPageInput = StubNotionSettingsClient.parentID
        client.createError = URLError(.timedOut)
        await model.createDatabase()
        XCTAssertEqual(client.createdParents, [StubNotionSettingsClient.parentID])
        XCTAssertEqual(settings.notionDatabaseID, "")
        XCTAssertFalse(model.isCreatingDatabase)
    }

    func testFailedSchemaUpgradeKeepsTheExportableSchema() async {
        let (_, client, model) = makeModel()
        await model.checkDatabaseSchema(id: StubNotionSettingsClient.databaseID)
        client.upgradeError = URLError(.timedOut)
        await model.upgradeDatabaseSchema()
        XCTAssertEqual(model.databaseSchemaStatus, client.schema)
        XCTAssertEqual(model.schemaCheckError?.contains("Failed to update"), true)
        XCTAssertFalse(model.upgradingSchema)
    }

    func testClosingSettingsCommitsTokenButClosingAnotherWindowDoesNot() {
        let (settings, _, model) = makeModel()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier("speaker-naming")
        model.apiKeyDraft = "pending-token"
        model.settingsWindowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertEqual(settings.notionAPIKey, "test-key")
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        model.settingsWindowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertEqual(settings.notionAPIKey, "pending-token")
    }

    func testChangingTokenWhileCreatingDatabaseDiscardsOldWorkspaceResult() async {
        let (settings, client, model) = makeModel()
        client.suspendCreation = true
        model.manualParentPageInput = StubNotionSettingsClient.parentID
        let creation = Task { await model.createDatabase() }
        while client.createContinuation == nil {
            await Task.yield()
        }

        model.apiKeyDraft = "other-workspace-token"
        model.commitAPIKey()
        client.createContinuation?.resume(returning: StubNotionSettingsClient.databaseID)
        await creation.value

        XCTAssertEqual(settings.notionDatabaseID, "")
        XCTAssertTrue(model.availableDatabases.isEmpty)
        XCTAssertTrue(client.schemaRequests.isEmpty)
        XCTAssertFalse(model.isCreatingDatabase)
    }

    func testMalformedCustomDatabaseInputShowsValidationAndEmptyInputDoesNot() async {
        let (_, client, model) = makeModel()
        await model.checkDatabaseSchema(id: "not-a-database")
        XCTAssertEqual(model.schemaCheckError?.contains("valid Notion database"), true)
        XCTAssertTrue(client.schemaRequests.isEmpty)
        await model.checkDatabaseSchema(id: "")
        XCTAssertNil(model.schemaCheckError)
    }

    func testHalfTypedCustomIDIsNotWrittenToSettings() {
        let (settings, _, model) = makeModel(databaseID: StubNotionSettingsClient.databaseID)
        model.setManualDatabaseInput("abc")
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.databaseID)
        model.setManualDatabaseInput(StubNotionSettingsClient.parentID)
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.parentID)
        model.setManualDatabaseInput("")
        XCTAssertEqual(settings.notionDatabaseID, "")
    }

    func testRefreshDoesNotPreselectAParentPage() async {
        let (_, client, model) = makeModel()
        client.pages = [NotionPageItem(id: StubNotionSettingsClient.parentID, title: "Team")]
        await model.refresh(silent: true)
        XCTAssertEqual(model.selectedParentPageID, "")
        XCTAssertFalse(model.isParentPageAvailable)
    }

    func testActivationRefreshIsThrottledAndNeedsAnEnabledConnection() async {
        let (settings, client, model) = makeModel()
        await model.refreshAfterActivation()
        XCTAssertEqual(client.databaseRequests, 0, "not connected yet")

        model.isNotionConnected = true
        await model.refreshAfterActivation()
        XCTAssertEqual(client.databaseRequests, 1)
        await model.refreshAfterActivation()
        XCTAssertEqual(client.databaseRequests, 1, "inside the 30 s throttle")

        settings.notionExportEnabled = false
        await model.refreshAfterActivation()
        XCTAssertEqual(client.databaseRequests, 1)
    }

    private func makeModel(databaseID: String = "") -> (AppSettings, StubNotionSettingsClient, NotionExportSettingsModel) {
        let suite = "NotionExportSettingsModelTests-\(UUID().uuidString)"
        let keyAccount = "notionKey.\(UUID().uuidString)"
        addTeardownBlock {
            DefaultsSuite.remove(suite)
            KeychainHelper.delete(key: keyAccount)
        }
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Cannot create test defaults") }
        let settings = AppSettings(defaults: defaults, notionAPIKeyAccount: keyAccount)
        settings.notionExportEnabled = true
        settings.notionAPIKey = "test-key"
        settings.notionDatabaseID = databaseID
        let client = StubNotionSettingsClient()
        return (settings, client, NotionExportSettingsModel(settings: settings) { _ in client })
    }
}
