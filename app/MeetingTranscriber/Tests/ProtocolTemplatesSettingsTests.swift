@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Settings → Output → Meeting Notes Templates: what deleting, the default picker
/// and the folder do to the folder and the default setting, then one wiring test
/// per control. The New Template window's behaviour is pinned in
/// `ProtocolTemplatesNewTemplateTests`, opening a template in
/// `ProtocolTemplatesOpeningTests`. Every test runs on `ProtocolTemplatesFixture`.
@MainActor
final class ProtocolTemplatesSettingsTests: XCTestCase {
    // MARK: - Model

    func testDeleteTrashesThroughTheInjectedTrashAndResetsADeletedDefault() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board", "Retro"])
        fixture.settings.defaultProtocolTemplate = .file(name: "Retro")
        let model = fixture.makeModel()

        model.requestDelete("Board")
        XCTAssertEqual(model.pendingDeletion, "Board")
        model.confirmDelete("Board")
        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Retro"), "deleting another template keeps the default")

        model.confirmDelete("Retro")

        XCTAssertEqual(fixture.trashed, [fixture.store.fileURL(named: "Board"), fixture.store.fileURL(named: "Retro")])
        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .builtIn)
        XCTAssertEqual(model.names, [])
        XCTAssertNil(model.notice)
    }

    func testAFailedDeleteShowsTheErrorAndKeepsTheTemplateAndTheDefault() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        fixture.settings.defaultProtocolTemplate = .file(name: "Board")
        let model = fixture.makeModel { url in
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }

        model.confirmDelete("Board")

        guard case .error = model.notice else {
            XCTFail("a failed delete shows a red line, got \(String(describing: model.notice))")
            return
        }
        XCTAssertEqual(fixture.files, ["Board.md"])
        XCTAssertEqual(model.names, ["Board"])
        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Board"))
    }

    func testDefaultSelectionShowsTheBuiltInForAMissingFileAndWritesTheSetting() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        fixture.settings.defaultProtocolTemplate = .file(name: "Gone")
        let model = fixture.makeModel()

        XCTAssertEqual(model.defaultSelection, .builtIn)
        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Gone"), "reading must not rewrite the setting")

        model.defaultSelection = .file(name: "Board")

        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Board"))
        XCTAssertEqual(model.defaultSelection, .file(name: "Board"))
    }

    /// Finder renames the default `Board.md` to `board.md`. On the default
    /// case-insensitive volume the stored "Board" still resolves, so the
    /// picker must select the listed "board", and deleting it resets the default.
    func testACaseOnlyRenameOfTheDefaultStaysSelectedAndDeletable() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let store = fixture.store
        let caseSensitive = try store.directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        try XCTSkipIf(caseSensitive == true, "a case-only rename only keeps the old name resolving on a case-insensitive volume")
        fixture.settings.defaultProtocolTemplate = .file(name: "Board")
        try FileManager.default.moveItem(at: store.fileURL(named: "Board"), to: store.fileURL(named: "board"))
        let model = fixture.makeModel()

        XCTAssertEqual(model.names, ["board"])
        XCTAssertEqual(model.defaultSelection, .file(name: "board"))

        model.confirmDelete("board")

        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .builtIn)
    }

    func testOpenFolderCreatesAMissingFolderWithoutTheMigrationMarker() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        try FileManager.default.removeItem(at: fixture.store.directory)
        let model = fixture.makeModel()

        model.openFolder()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(fixture.files, [], "the migration marker is the migration's to write")
        XCTAssertEqual(fixture.openedFolders, [fixture.store.directory])
        XCTAssertNil(model.notice)
    }

    /// A file where the folder should be: the folder cannot be created, the
    /// error shows, nothing opens, and the next open that works clears it.
    func testAFolderThatCannotBeCreatedShowsTheErrorAndOpensNothing() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        try FileManager.default.removeItem(at: fixture.store.directory)
        try Data().write(to: fixture.store.directory)
        let model = fixture.makeModel()

        model.openFolder()

        guard case .error = model.notice else {
            XCTFail("a folder that cannot be made shows a red line, got \(String(describing: model.notice))")
            return
        }
        XCTAssertEqual(fixture.openedFolders, [])

        try FileManager.default.removeItem(at: fixture.store.directory)
        model.openFolder()

        XCTAssertNil(model.notice)
    }

    func testReloadPicksUpAFileAddedOnDisk() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()
        XCTAssertEqual(model.names, ["Board"])

        try fixture.write(["Retro"])
        model.reload()

        XCTAssertEqual(model.names, ["Board", "Retro"])
    }

    // MARK: - Wiring

    /// The section over a folder holding the templates "Board" and "Retro".
    private func makeView() throws -> (ProtocolTemplatesSettingsView, ProtocolTemplatesModel, ProtocolTemplatesFixture) {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board", "Retro"])
        let model = fixture.makeModel()
        return (ProtocolTemplatesSettingsView(model: model), model, fixture)
    }

    private func button(_ identifier: String, in view: ProtocolTemplatesSettingsView) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(viewWithAccessibilityIdentifier: identifier).button()
    }

    /// The New Template window, opened with its button.
    private func newTemplateSheet(in view: ProtocolTemplatesSettingsView) throws -> InspectableView<ViewType.Sheet> {
        try button(A11yID.protocolTemplateNewButton, in: view).tap()
        return try view.inspect().find(ViewType.Sheet.self)
    }

    func testDefaultPickerWritesTheSetting() throws {
        let (view, _, fixture) = try makeView()

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.protocolTemplateDefaultPicker)
            .find(ViewType.Picker.self)
            .select(value: ProtocolTemplateID.file(name: "Retro"))

        XCTAssertEqual(fixture.settings.defaultProtocolTemplate, .file(name: "Retro"))
    }

    func testNewTemplatePresentsTheWindow() throws {
        let (view, model, _) = try makeView()
        XCTAssertThrowsError(try view.inspect().find(ViewType.Sheet.self), "no window before the click")

        let sheet = try newTemplateSheet(in: view)

        XCTAssertTrue(model.isNewTemplateShown)
        XCTAssertNoThrow(try sheet.find(text: "New Template"))
    }

    func testTheWindowsNameFieldWritesTheModel() throws {
        let (view, model, _) = try makeView()

        try newTemplateSheet(in: view)
            .find(ViewType.TextField.self) { try $0.accessibilityIdentifier() == A11yID.protocolTemplateNewNameField }
            .setInput("Workshop")

        XCTAssertEqual(model.newTemplateName, "Workshop")
    }

    func testTheWindowsCancelClosesItWithoutWriting() throws {
        let (view, model, fixture) = try makeView()
        let sheet = try newTemplateSheet(in: view)
        model.newTemplateName = "Workshop"

        try sheet.find(viewWithAccessibilityIdentifier: A11yID.protocolTemplateNewCancelButton).button().tap()

        XCTAssertFalse(model.isNewTemplateShown)
        XCTAssertEqual(fixture.files, ["Board.md", "Retro.md"])
    }

    func testTheWindowsCreateCreatesTheTypedTemplateAndOpensNothing() throws {
        let (view, model, fixture) = try makeView()
        let sheet = try newTemplateSheet(in: view)
        model.newTemplateName = "Workshop"

        try sheet.find(viewWithAccessibilityIdentifier: A11yID.protocolTemplateNewCreateButton).button().tap()

        XCTAssertEqual(model.names, ["Board", "Retro", "Workshop"])
        XCTAssertNil(model.openTask)
        XCTAssertEqual(fixture.apps.opened, [])
    }

    /// The window shows the note, which names no app; the help text names
    /// the editor app, here the Mac's default.
    func testTheWindowShowsTheNoteAndTheHelpTextNamesTheEditorApp() throws {
        let (view, _, _) = try makeView()
        let sheet = try newTemplateSheet(in: view)

        XCTAssertNoThrow(try sheet.find(text: ProtocolTemplatesModel.newTemplateNote(name: "")))
        XCTAssertNoThrow(try view.inspect().find(text: TemplateEditor.app(FakeTemplateOpener.textEdit).helpText))
    }

    func testEditOfRowZeroOpensItInTheEditorApp() async throws {
        let (view, model, fixture) = try makeView()

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.protocolTemplateEdit(0))
            .find(ViewType.Menu.self)
            .callPrimaryAction()
        await model.openTask?.value

        XCTAssertEqual(fixture.apps.opened, [.init(file: fixture.store.fileURL(named: "Board"), app: "com.apple.TextEdit")])
    }

    func testOpenInTheEditorAppOfRowOneOpensIt() async throws {
        let (view, model, fixture) = try makeView()

        let item = try button(A11yID.protocolTemplateOpenInEditor(1), in: view)
        XCTAssertEqual(try item.labelView().text().string(), "Open in TextEdit")
        try item.tap()
        await model.openTask?.value

        XCTAssertEqual(fixture.apps.opened, [.init(file: fixture.store.fileURL(named: "Retro"), app: "com.apple.TextEdit")])
    }

    /// Open With lists the default app first, then Visual Studio Code.
    func testAnOpenWithAppOfRowZeroOpensItAndBecomesTheEditor() async throws {
        let (view, model, fixture) = try makeView()

        try button(A11yID.protocolTemplateOpenWithApp(0, 1), in: view).tap()
        await model.openTask?.value

        XCTAssertEqual(fixture.apps.opened, [.init(file: fixture.store.fileURL(named: "Board"), app: "com.microsoft.VSCode")])
        XCTAssertEqual(fixture.settings.templateEditorBundleIdentifier, "com.microsoft.VSCode")
    }

    func testOtherOfRowZeroAsksForAnApp() async throws {
        let (view, model, fixture) = try makeView()
        fixture.apps.chosen = FakeTemplateOpener.typora

        try button(A11yID.protocolTemplateOpenWithOther(0), in: view).tap()
        await model.openTask?.value

        XCTAssertEqual(fixture.apps.pickerShown, 1)
        XCTAssertEqual(fixture.apps.opened, [.init(file: fixture.store.fileURL(named: "Board"), app: "abnerworks.Typora")])
    }

    func testShowInFinderOfRowZeroRevealsIt() throws {
        let (view, _, fixture) = try makeView()

        try button(A11yID.protocolTemplateShowInFinder(0), in: view).tap()

        XCTAssertEqual(fixture.apps.revealed, [fixture.store.fileURL(named: "Board")])
    }

    func testDeleteOfRowZeroAsksForConfirmation() throws {
        let (view, model, fixture) = try makeView()

        try button(A11yID.protocolTemplateDelete(0), in: view).tap()

        XCTAssertEqual(model.pendingDeletion, "Board")
        XCTAssertEqual(fixture.files, ["Board.md", "Retro.md"], "nothing is deleted before the confirmation")
    }

    func testOpenFolderButtonOpensTheFolder() throws {
        let (view, _, fixture) = try makeView()

        try button(A11yID.protocolTemplatesOpenFolderButton, in: view).tap()

        XCTAssertEqual(fixture.openedFolders, [fixture.store.directory])
    }
}
