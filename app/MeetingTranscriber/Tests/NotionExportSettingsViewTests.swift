@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class NotionExportSettingsViewTests: XCTestCase {
    func testExportToggleWritesItsSetting() throws {
        let (settings, _, _, view) = makeView()
        try toggle(A11yID.notionExportToggle, in: view).tap()
        XCTAssertFalse(settings.notionExportEnabled)
    }

    func testNoticeShowsWhileNoDatabaseIsSelectedAndClearsOnceOneIs() throws {
        let (settings, _, model, view) = makeView()
        XCTAssertNotNil(model.configurationNotice)
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: A11yID.notionConfigurationNotice))
        settings.notionDatabaseID = "database-1"
        XCTAssertNil(model.configurationNotice)
        settings.notionExportEnabled = false
        settings.notionDatabaseID = ""
        XCTAssertNil(model.configurationNotice)
    }

    func testReCreatingTheViewDoesNotBuildAModel() {
        let (settings, _, model, _) = makeView()
        var built = 0
        func counted() -> NotionExportSettingsModel {
            built += 1
            return model
        }
        _ = NotionExportSettingsView(settings: settings, model: counted())
        XCTAssertEqual(built, 0)
    }

    func testSkipLocalToggleIsOffByDefaultAndWritesItsSettingWithoutAConnection() throws {
        let (settings, _, _, view) = makeView(connected: false)
        XCTAssertFalse(settings.notionSkipLocalMarkdownOnSuccess)
        try toggle(A11yID.notionSkipLocalMarkdownToggle, in: view).tap()
        XCTAssertTrue(settings.notionSkipLocalMarkdownOnSuccess)
    }

    func testSpeakerTagsToggleIsOptInAndWritesItsSetting() throws {
        let (settings, _, _, view) = makeView()
        XCTAssertFalse(settings.notionSpeakerTagsEnabled)
        try toggle(A11yID.notionSpeakerTagsToggle, in: view).tap()
        XCTAssertTrue(settings.notionSpeakerTagsEnabled)
    }

    func testAPIKeyFieldKeepsTypingInDraftAndCommitsOnSubmit() throws {
        let (settings, _, model, view) = makeView()
        let field = try view.inspect().find(ViewType.SecureField.self) { field in
            try field.accessibilityIdentifier() == A11yID.notionAPIKeyField
        }
        try field.setInput("new-token")
        XCTAssertEqual(settings.notionAPIKey, "test-key")
        XCTAssertEqual(model.apiKeyDraft, "new-token")
        try field.callOnSubmit()
        XCTAssertEqual(settings.notionAPIKey, "new-token")
        XCTAssertFalse(model.isNotionConnected)
    }

    func testAPIKeyFieldCommitsOnFocusLossAndDisappearance() throws {
        let (settings, _, _, view) = makeView()
        let field = try view.inspect().find(ViewType.SecureField.self) { field in
            try field.accessibilityIdentifier() == A11yID.notionAPIKeyField
        }
        try field.setInput("focus-token")
        try field.callOnChange(oldValue: true, newValue: false)
        XCTAssertEqual(settings.notionAPIKey, "focus-token")
        try field.setInput("last-token")
        try field.callOnDisappear()
        XCTAssertEqual(settings.notionAPIKey, "last-token")
    }

    func testTestConnectionCommitsPendingTokenAndUsesInjectedClient() async throws {
        let (settings, client, model, view) = makeView(connected: false)
        model.apiKeyDraft = "pasted-token"
        try button(A11yID.notionTestConnectionButton, in: view).tap()
        XCTAssertEqual(settings.notionAPIKey, "pasted-token")
        await waitUntil { client.databaseRequests == 1 && !model.testingNotion }
        XCTAssertTrue(model.isNotionConnected)
        XCTAssertEqual(client.pageRequests, 1)
    }

    func testRefreshButtonUsesInjectedClient() async throws {
        let (_, client, model, view) = makeView()
        try button(A11yID.notionRefreshButton, in: view).tap()
        await waitUntil { client.databaseRequests == 1 && !model.testingNotion }
        XCTAssertEqual(client.pageRequests, 1)
    }

    func testDatabasePickerSavesExplicitChoiceAndChecksItOnce() async throws {
        let (settings, client, model, view) = makeView()
        model.availableDatabases = [NotionDatabaseItem(id: StubNotionSettingsClient.databaseID, title: "Team notes")]
        let picker = try view.inspect().find(ViewType.Picker.self) { picker in
            try picker.accessibilityIdentifier() == A11yID.notionDatabasePicker
        }
        try picker.select(value: StubNotionSettingsClient.databaseID)
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.databaseID)
        await waitUntil { client.schemaRequests.count == 1 && !model.checkingSchema }
        XCTAssertEqual(client.schemaRequests, [StubNotionSettingsClient.databaseID])
    }

    func testSuggestedDatabaseRequiresConfirmationButton() throws {
        let (settings, _, model, view) = makeView()
        model.selectedDatabaseTag = StubNotionSettingsClient.databaseID
        model.availableDatabases = [NotionDatabaseItem(id: StubNotionSettingsClient.databaseID, title: "Meeting Transcriber")]
        XCTAssertEqual(settings.notionDatabaseID, "")
        try button(A11yID.notionConfirmDatabaseButton, in: view).tap()
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.databaseID)
    }

    func testManualDatabaseFieldWritesCanonicalIDAndChecksSchema() async throws {
        let (settings, client, model, view) = makeView()
        model.selectedDatabaseTag = NotionExportSettingsModel.customDatabaseTag
        let field = try view.inspect().find(ViewType.TextField.self) { field in
            try field.accessibilityIdentifier() == A11yID.notionDatabaseIDField
        }
        try field.setInput("https://notion.so/Notes-\(StubNotionSettingsClient.databaseID)")
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.databaseID)
        await waitUntil { client.schemaRequests.count == 1 }
        XCTAssertEqual(client.schemaRequests, [StubNotionSettingsClient.databaseID])
    }

    func testParentPickerSelectsWhereCreateButtonWrites() async throws {
        let (_, client, model, view) = makeView()
        model.availablePages = [NotionPageItem(id: StubNotionSettingsClient.parentID, title: "Team")]
        let picker = try view.inspect().find(ViewType.Picker.self) { picker in
            try picker.accessibilityIdentifier() == A11yID.notionParentPagePicker
        }
        try picker.select(value: StubNotionSettingsClient.parentID)
        XCTAssertEqual(model.selectedParentPageID, StubNotionSettingsClient.parentID)
        try button(A11yID.notionInitDatabaseButton, in: view).tap()
        await waitUntil { !client.createdParents.isEmpty && !model.isCreatingDatabase }
        XCTAssertEqual(client.createdParents, [StubNotionSettingsClient.parentID])
    }

    func testManualParentFieldSelectsWhereCreateButtonWrites() async throws {
        let (settings, client, model, view) = makeView()
        let field = try view.inspect().find(ViewType.TextField.self) { field in
            try field.accessibilityIdentifier() == A11yID.notionParentPageField
        }
        try field.setInput("https://notion.so/Team-\(StubNotionSettingsClient.parentID)")
        XCTAssertEqual(model.manualParentPageInput, "https://notion.so/Team-\(StubNotionSettingsClient.parentID)")
        try button(A11yID.notionInitDatabaseButton, in: view).tap()
        await waitUntil { !client.createdParents.isEmpty && !model.isCreatingDatabase }
        XCTAssertEqual(client.createdParents, [StubNotionSettingsClient.parentID])
        XCTAssertEqual(settings.notionDatabaseID, StubNotionSettingsClient.databaseID)
    }

    func testUpgradeButtonRequestsMissingOptionalColumns() async throws {
        let (_, client, model, view) = makeView()
        model.selectedDatabaseTag = StubNotionSettingsClient.databaseID
        model.databaseSchemaStatus = client.schema
        try button(A11yID.notionUpgradeSchemaButton, in: view).tap()
        await waitUntil { !client.upgradedDatabases.isEmpty && !model.upgradingSchema }
        XCTAssertEqual(client.upgradedDatabases, [StubNotionSettingsClient.databaseID])
        XCTAssertEqual(model.databaseSchemaStatus?.hasAllOptionalColumns, true)
    }

    func testRecordOnlyModeDisablesExportSection() throws {
        let (settings, _, _, view) = makeView()
        settings.recordOnly = true
        XCTAssertTrue(try toggle(A11yID.notionExportToggle, in: view).isDisabled())
    }

    private func toggle(_ id: String, in view: NotionExportSettingsView) throws -> InspectableView<ViewType.Toggle> {
        try view.inspect().find(ViewType.Toggle.self) { try $0.accessibilityIdentifier() == id }
    }

    private func button(_ id: String, in view: NotionExportSettingsView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(ViewType.Button.self) { try $0.accessibilityIdentifier() == id }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        // Sleeps rather than yields, and long enough for a loaded parallel run:
        // spinning here starves the main-actor work being waited for.
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Settings action did not finish")
    }

    private func makeView(connected: Bool = true) -> (AppSettings, StubNotionSettingsClient, NotionExportSettingsModel, NotionExportSettingsView) {
        let suite = "NotionExportSettingsViewTests-\(UUID().uuidString)"
        let keyAccount = "notionKey.\(UUID().uuidString)"
        addTeardownBlock {
            DefaultsSuite.remove(suite)
            KeychainHelper.delete(key: keyAccount)
        }
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Cannot create test defaults") }
        let settings = AppSettings(defaults: defaults, notionAPIKeyAccount: keyAccount)
        settings.notionExportEnabled = true
        settings.notionAPIKey = "test-key"
        let client = StubNotionSettingsClient()
        let model = NotionExportSettingsModel(settings: settings) { _ in client }
        model.isNotionConnected = connected
        return (settings, client, model, NotionExportSettingsView(settings: settings, model: model))
    }
}
