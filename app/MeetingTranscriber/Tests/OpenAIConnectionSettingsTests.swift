@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the saved-connection controls in Settings → Output → AI Provider; the
/// switching logic itself is pinned in `AppSettingsOpenAIConnectionsTests`.
@MainActor
final class OpenAIConnectionSettingsTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var apiKeyAccount: String!
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        let unique = "\(getpid())-\(UUID().uuidString)"
        suiteName = "OpenAIConnectionSettingsTests-\(unique)"
        apiKeyAccount = "OpenAIConnectionSettingsTests-openAIAPIKey-\(unique)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
        settings = AppSettings(defaults: defaults, apiKeyAccount: apiKeyAccount)
        settings.protocolProvider = .openAICompatible
    }

    override func tearDown() async throws {
        for connection in settings.openAIConnections {
            KeychainHelper.delete(key: settings.openAIKeyAccount(for: connection))
        }
        KeychainHelper.delete(key: apiKeyAccount)
        settings = nil
        DefaultsSuite.remove(suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testPickerSelectsTheConnectionAndShowsItsKey() throws {
        settings.openAIAPIKey = "sk-work"
        let work = settings.activeOpenAIConnectionID
        settings.addOpenAIConnection()
        settings.openAIAPIKey = "sk-local"
        let drafts = ProtocolAPIKeyDrafts(settings: settings)
        let view = OutputSettingsView(settings: settings, apiKeyDrafts: drafts)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIConnectionPicker)
            .find(ViewType.Picker.self)
            .select(value: work)

        XCTAssertEqual(settings.activeOpenAIConnectionID, work)
        XCTAssertEqual(drafts.openAI, "sk-work")
    }

    func testSwitchingHandsATypedKeyToTheConnectionBeingLeft() throws {
        let work = settings.activeOpenAIConnectionID
        settings.addOpenAIConnection()
        let local = settings.activeOpenAIConnectionID
        let drafts = ProtocolAPIKeyDrafts(settings: settings)
        drafts.openAI = "sk-typed-not-committed"
        let view = OutputSettingsView(settings: settings, apiKeyDrafts: drafts)

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIConnectionPicker)
            .find(ViewType.Picker.self)
            .select(value: work)

        XCTAssertEqual(settings.openAIAPIKey, "")
        settings.selectOpenAIConnection(local)
        XCTAssertEqual(settings.openAIAPIKey, "sk-typed-not-committed")
    }

    /// Controls with `prompts` and a switch that records it ran around the change.
    private func makeControls(_ prompts: OpenAIConnectionPrompts, switches: @escaping () -> Void = {}) -> OpenAIConnectionControls {
        OpenAIConnectionControls(settings: settings, prompts: prompts) { change in
            switches()
            change()
        }
    }

    func testAddButtonAsksForANameAndCreatesNothing() throws {
        let prompts = OpenAIConnectionPrompts()

        try makeControls(prompts).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIConnectionAddButton)
            .find(ViewType.Button.self)
            .tap()

        XCTAssertTrue(prompts.isAdding)
        XCTAssertEqual(prompts.newName, "Connection 2")
        XCTAssertEqual(settings.openAIConnections.count, 1)
    }

    func testCreatingAddsTheNamedConnectionThroughTheSwitch() {
        let first = settings.activeOpenAIConnectionID
        let prompts = OpenAIConnectionPrompts()
        prompts.beginAdd(settings: settings)
        prompts.newName = "  Work Azure "
        var switched = 0

        makeControls(prompts) { switched += 1 }.confirmAdd()

        XCTAssertEqual(settings.activeOpenAIConnection?.name, "Work Azure")
        XCTAssertNotEqual(settings.activeOpenAIConnectionID, first)
        XCTAssertEqual(switched, 1, "the key draft must be handed over around the change")
        XCTAssertFalse(prompts.isAdding)
    }

    func testABlankNameCreatesNothing() {
        let prompts = OpenAIConnectionPrompts()
        prompts.beginAdd(settings: settings)
        prompts.newName = "   "

        XCTAssertFalse(prompts.canCreate)
        makeControls(prompts).confirmAdd()

        XCTAssertEqual(settings.openAIConnections.count, 1)
    }

    func testRenameButtonAsksForTheSelectedConnectionsNameAndRenamesNothing() throws {
        settings.renameActiveOpenAIConnection("Work")
        let selected = settings.activeOpenAIConnection
        let prompts = OpenAIConnectionPrompts()

        try makeControls(prompts).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIConnectionRenameButton)
            .find(ViewType.Button.self)
            .tap()

        XCTAssertEqual(prompts.renaming, selected)
        XCTAssertEqual(prompts.renameName, "Work")
        XCTAssertEqual(settings.activeOpenAIConnection?.name, "Work")
    }

    func testRenamingAConnectionWithAClearedNameStartsEmpty() {
        settings.renameActiveOpenAIConnection("")
        let prompts = OpenAIConnectionPrompts()

        prompts.beginRename(settings: settings)

        XCTAssertEqual(prompts.renameName, "", "the picker's placeholder label must not become the name")
        XCTAssertFalse(prompts.canRename)
    }

    func testConfirmingRenameRenamesTheSelectedConnection() {
        let prompts = OpenAIConnectionPrompts()
        prompts.beginRename(settings: settings)
        prompts.renameName = "  Work Azure "

        makeControls(prompts).confirmRename()

        XCTAssertEqual(settings.activeOpenAIConnection?.name, "Work Azure")
        XCTAssertNil(prompts.renaming)
    }

    func testABlankRenameKeepsTheName() {
        settings.renameActiveOpenAIConnection("Work")
        let prompts = OpenAIConnectionPrompts()
        prompts.beginRename(settings: settings)
        prompts.renameName = "   "

        XCTAssertFalse(prompts.canRename)
        makeControls(prompts).confirmRename()

        XCTAssertEqual(settings.activeOpenAIConnection?.name, "Work")
    }

    func testConfirmingRenameDoesNothingOnceAnotherConnectionIsSelected() {
        let first = settings.activeOpenAIConnectionID
        settings.addOpenAIConnection(named: "Local")
        let prompts = OpenAIConnectionPrompts()
        prompts.beginRename(settings: settings)
        prompts.renameName = "Renamed"
        settings.selectOpenAIConnection(first)

        makeControls(prompts).confirmRename()

        XCTAssertFalse(settings.openAIConnections.map(\.name).contains("Renamed"))
    }

    func testDeleteButtonAsksAboutTheSelectedConnectionAndDeletesNothing() throws {
        settings.addOpenAIConnection()
        let selected = settings.activeOpenAIConnection
        let prompts = OpenAIConnectionPrompts()

        try makeControls(prompts).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIConnectionDeleteButton)
            .find(ViewType.Button.self)
            .tap()

        XCTAssertEqual(prompts.deleting, selected)
        XCTAssertEqual(settings.openAIConnections.count, 2)
    }

    func testConfirmingDeleteDeletesTheSelectedConnectionThroughTheSwitch() {
        let first = settings.activeOpenAIConnectionID
        settings.addOpenAIConnection()
        let prompts = OpenAIConnectionPrompts()
        prompts.beginDelete(settings: settings)
        var switched = 0

        makeControls(prompts) { switched += 1 }.confirmDelete()

        XCTAssertEqual(settings.openAIConnections.map(\.id), [first])
        XCTAssertEqual(switched, 1, "the key draft must be handed over around the change")
        XCTAssertNil(prompts.deleting)
    }

    func testConfirmingDeleteDoesNothingOnceAnotherConnectionIsSelected() {
        let first = settings.activeOpenAIConnectionID
        settings.addOpenAIConnection()
        let prompts = OpenAIConnectionPrompts()
        prompts.beginDelete(settings: settings)
        settings.selectOpenAIConnection(first)

        makeControls(prompts).confirmDelete()

        XCTAssertEqual(settings.openAIConnections.count, 2)
    }

    func testDeleteButtonIsDisabledForTheLastConnection() throws {
        let button = try OutputSettingsView(settings: settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.openAIConnectionDeleteButton)
            .find(ViewType.Button.self)

        XCTAssertTrue(button.isDisabled())
    }
}
