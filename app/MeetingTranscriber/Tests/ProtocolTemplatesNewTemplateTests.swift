@testable import MeetingTranscriber
import XCTest

/// The New Template window's state and writes, on `ProtocolTemplatesModel`: what
/// Create writes, that it opens nothing, the note, the red line under the name,
/// and what Cancel and a failed write leave behind. The window's controls are
/// wired in `ProtocolTemplatesSettingsTests`.
@MainActor
final class ProtocolTemplatesNewTemplateTests: XCTestCase {
    /// Create only writes the file; Edit opens it afterwards, in the same app
    /// as every other template.
    func testCreateWritesTheBuiltInTextClosesTheWindowAndOpensNothing() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "  Board  "

        model.createTemplate()

        let url = fixture.store.fileURL(named: "Board")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ProtocolGenerator.protocolPrompt)
        XCTAssertFalse(model.isNewTemplateShown)
        XCTAssertEqual(model.newTemplateName, "")
        XCTAssertEqual(model.names, ["Board"])
        XCTAssertNil(model.openTask)
        XCTAssertEqual(fixture.apps.opened, [])
        XCTAssertEqual(fixture.apps.revealed, [])
        XCTAssertNil(model.notice)
    }

    /// The note names no app, so it never disagrees with the app Edit uses.
    func testTheNoteSaysCreateOnlyWritesTheFileAndEditOpensIt() {
        XCTAssertEqual(ProtocolTemplatesModel.newTemplateNote(name: " Daily stand-up "), """
        Creates “Daily stand-up.md” in the templates folder from the built-in template. To change it, click Edit \
        in its row; the arrow beside Edit lets you pick the app.
        """)
        XCTAssertEqual(ProtocolTemplatesModel.newTemplateNote(name: ""), """
        Creates a Markdown file in the templates folder from the built-in template. To change it, click Edit in \
        its row; the arrow beside Edit lets you pick the app.
        """)
    }

    func testARefusedNameShowsTheStoresMessageAndDisablesCreate() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()
        model.showNewTemplate()
        let cases: [(String, ProtocolTemplateName.Refusal)] = [
            (String(repeating: "x", count: ProtocolTemplateName.maxLength + 1), .tooLong),
            ("a/b", .forbiddenCharacter),
            ("a:b", .forbiddenCharacter),
            (".hidden", .leadingDot),
            ("board", .duplicate),
        ]
        for (raw, refusal) in cases {
            model.newTemplateName = raw

            XCTAssertEqual(model.nameProblem, refusal.errorDescription, raw)
            XCTAssertFalse(model.canCreate, raw)
        }
        XCTAssertEqual(fixture.files, ["Board.md"])
    }

    func testAnEmptyNameDisablesCreateWithoutARedLine() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.showNewTemplate()

        for raw in ["", "   "] {
            model.newTemplateName = raw

            XCTAssertNil(model.nameProblem, "“\(raw)”")
            XCTAssertFalse(model.canCreate, "“\(raw)”")
        }
        model.newTemplateName = "Retro"
        XCTAssertTrue(model.canCreate)
    }

    func testAFailedWriteKeepsTheWindowAndTheNameAndShowsTheError() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let folder = fixture.store.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "Retro"

        model.createTemplate()

        XCTAssertTrue(model.isNewTemplateShown)
        XCTAssertEqual(model.newTemplateName, "Retro")
        XCTAssertNotNil(model.nameProblem)
        XCTAssertNil(model.openTask)
        XCTAssertEqual(fixture.files, ["Board.md"])
        XCTAssertEqual(fixture.apps.opened, [])

        model.newTemplateName = "Retro 2"
        XCTAssertNil(model.nameProblem, "typing again clears the error")
    }

    /// Another app wrote the name while the window was open: Create checks
    /// again, refuses it and leaves that file alone.
    func testANameTakenWhileTheWindowIsOpenIsRefusedOnCreate() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "Retro"
        XCTAssertTrue(model.canCreate)
        try fixture.write(["Retro"])

        model.createTemplate()

        XCTAssertTrue(model.isNewTemplateShown)
        XCTAssertEqual(model.nameProblem, ProtocolTemplateName.Refusal.duplicate.errorDescription)
        XCTAssertFalse(model.canCreate)
        XCTAssertEqual(try String(contentsOf: fixture.store.fileURL(named: "Retro"), encoding: .utf8), "Template Retro")
        XCTAssertEqual(fixture.apps.opened, [])
    }

    func testCancelClosesTheWindowWithoutWritingAndANewWindowStartsEmpty() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "Retro"

        model.cancelNewTemplate()

        XCTAssertFalse(model.isNewTemplateShown)
        XCTAssertEqual(fixture.files, [])

        model.showNewTemplate()
        XCTAssertEqual(model.newTemplateName, "")
    }

    /// No template exists yet and no app was ever chosen: the help text names
    /// the Mac's default app for Markdown files, the note no app.
    func testWithAnEmptyFolderTheHelpTextNamesTheDefaultMarkdownAppAndTheNoteNone() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        let model = fixture.makeModel()
        model.newTemplateName = "Board"

        XCTAssertEqual(model.editor, .app(FakeTemplateOpener.textEdit))
        XCTAssertTrue(model.editor.helpText.contains("Edit opens one in TextEdit."))
        XCTAssertEqual(model.newTemplateNote, ProtocolTemplatesModel.newTemplateNote(name: "Board"))
        XCTAssertFalse(model.newTemplateNote.contains("TextEdit"))
    }

    /// With no app for Markdown files, Create still only writes the file:
    /// nothing goes to Finder and no orange line appears.
    func testWithoutAMarkdownAppCreateStillOnlyWritesTheFile() throws {
        let fixture = try ProtocolTemplatesFixture(self)
        fixture.apps.defaultApp = nil
        fixture.apps.offered = []
        let model = fixture.makeModel()
        model.showNewTemplate()
        model.newTemplateName = "Board"

        model.createTemplate()

        XCTAssertEqual(fixture.files, ["Board.md"])
        XCTAssertEqual(fixture.apps.revealed, [])
        XCTAssertNil(model.notice)
    }
}
