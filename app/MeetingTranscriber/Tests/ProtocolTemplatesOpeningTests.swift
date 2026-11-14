@testable import MeetingTranscriber
import XCTest

/// Opening a template on `ProtocolTemplatesModel`: Edit opens it in the editor
/// app, Open With and Other… change that app for every template and keep it
/// across a relaunch, and a template that cannot be opened is shown in Finder
/// with the orange line. The menu's controls are wired in
/// `ProtocolTemplatesSettingsTests`.
@MainActor
final class ProtocolTemplatesOpeningTests: XCTestCase {
    private typealias Fake = FakeTemplateOpener

    func testEditOpensTheTemplateInTheDefaultAppWhenNothingIsRemembered() async throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()

        model.edit("Board")
        await model.openTask?.value

        XCTAssertEqual(fixture.apps.opened, [.init(file: fixture.store.fileURL(named: "Board"), app: "com.apple.TextEdit")])
        XCTAssertEqual(fixture.apps.revealed, [])
        XCTAssertNil(fixture.settings.templateEditorBundleIdentifier)
    }

    /// Visual Studio Code chosen for Board opens Retro too, also in the
    /// section a relaunch builds from the same settings.
    func testOpenWithOpensTheTemplateAndBecomesTheEditorForEveryTemplateAcrossARelaunch() async throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board", "Retro"])
        let model = fixture.makeModel()

        model.openWith(Fake.code, template: "Board")
        await model.openTask?.value
        model.edit("Retro")
        await model.openTask?.value

        XCTAssertEqual(fixture.settings.templateEditorBundleIdentifier, "com.microsoft.VSCode")
        XCTAssertEqual(fixture.apps.opened, [
            .init(file: fixture.store.fileURL(named: "Board"), app: "com.microsoft.VSCode"),
            .init(file: fixture.store.fileURL(named: "Retro"), app: "com.microsoft.VSCode"),
        ])

        let relaunched = fixture.makeModel(settings: AppSettings(defaults: fixture.defaults))
        relaunched.edit("Board")
        await relaunched.openTask?.value

        XCTAssertEqual(fixture.apps.opened.last, .init(file: fixture.store.fileURL(named: "Board"), app: "com.microsoft.VSCode"))
        XCTAssertEqual(relaunched.editor.appName, "Visual Studio Code")
    }

    /// Typora is not among the apps macOS offers for Markdown files, and stays
    /// the editor anyway.
    func testOtherOpensTheTemplateInThePickedAppAndRemembersIt() async throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        fixture.apps.chosen = Fake.typora
        let model = fixture.makeModel()

        model.openWithOtherApp(template: "Board")
        await model.openTask?.value

        XCTAssertEqual(fixture.apps.pickerShown, 1)
        XCTAssertEqual(fixture.settings.templateEditorBundleIdentifier, "abnerworks.Typora")
        XCTAssertEqual(fixture.apps.opened, [.init(file: fixture.store.fileURL(named: "Board"), app: "abnerworks.Typora")])
        XCTAssertEqual(model.editor, .app(Fake.typora))
    }

    func testCancellingOtherChangesNothing() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()

        model.openWithOtherApp(template: "Board")

        XCTAssertEqual(fixture.apps.pickerShown, 1)
        XCTAssertNil(fixture.settings.templateEditorBundleIdentifier)
        XCTAssertNil(model.openTask)
    }

    func testShowInFinderRevealsTheTemplate() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let model = fixture.makeModel()

        model.showInFinder("Board")

        XCTAssertEqual(fixture.apps.revealed, [fixture.store.fileURL(named: "Board")])
        XCTAssertEqual(fixture.apps.opened, [])
        XCTAssertNil(model.notice)
    }

    /// The red line stays until a Show in Finder works.
    func testAShowInFinderThatFailsShowsTheErrorInRed() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        let error = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fixture.store.fileURL(named: "Board").path])
        fixture.apps.revealError = error
        let model = fixture.makeModel()

        model.showInFinder("Board")

        XCTAssertEqual(model.notice, .error(error.localizedDescription))

        fixture.apps.revealError = nil
        model.showInFinder("Board")

        XCTAssertNil(model.notice)
    }

    /// The app chosen under Open With fails: the file is shown in Finder with
    /// the orange line, the choice is kept, and the next successful open
    /// clears the line.
    func testAnAppThatCannotOpenTheTemplateLeadsToFinderUntilTheNextOpenWorks() async throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        fixture.apps.failing = ["com.microsoft.VSCode"]
        let model = fixture.makeModel()

        model.openWith(Fake.code, template: "Board")
        await model.openTask?.value

        XCTAssertEqual(fixture.apps.revealed, [fixture.store.fileURL(named: "Board")])
        let line = TemplateOpenFailure.couldNotOpen(app: "Visual Studio Code").shownInFinder(file: "Board.md")
        XCTAssertEqual(model.notice, .warning(line))
        XCTAssertEqual(fixture.settings.templateEditorBundleIdentifier, "com.microsoft.VSCode")

        fixture.apps.failing = []
        model.edit("Board")
        await model.openTask?.value

        XCTAssertNil(model.notice)
    }

    func testARememberedAppThatIsGoneLeadsToFinderAndIsForgotten() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        fixture.settings.templateEditorBundleIdentifier = "abnerworks.Typora"
        fixture.apps.installed = [Fake.textEdit]
        let model = fixture.makeModel()

        model.edit("Board")

        XCTAssertEqual(fixture.apps.revealed, [fixture.store.fileURL(named: "Board")])
        XCTAssertEqual(fixture.apps.opened, [])
        XCTAssertEqual(model.notice, .warning(TemplateOpenFailure.notFound(app: "abnerworks.Typora").shownInFinder(file: "Board.md")))
        XCTAssertNil(fixture.settings.templateEditorBundleIdentifier)
        XCTAssertEqual(model.editor, .app(Fake.textEdit), "the next Edit uses the default app")
    }

    func testWithoutAnAppForMarkdownFilesEditShowsTheTemplateInFinder() throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        fixture.apps.defaultApp = nil
        fixture.apps.offered = []
        let model = fixture.makeModel()

        model.edit("Board")

        XCTAssertEqual(fixture.apps.revealed, [fixture.store.fileURL(named: "Board")])
        XCTAssertEqual(model.notice, .warning(TemplateOpenFailure.noApp.shownInFinder(file: "Board.md")))
        XCTAssertNil(model.editor.appName)
        XCTAssertEqual(model.openWithEntries, [.other])
    }

    /// Finder cannot show the file either: the line names Finder's error.
    func testWhenFinderCannotShowTheTemplateEitherTheLineNamesTheError() async throws {
        let fixture = try ProtocolTemplatesFixture(self, templates: ["Board"])
        fixture.apps.failing = ["com.apple.TextEdit"]
        let error = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fixture.store.fileURL(named: "Board").path])
        fixture.apps.revealError = error
        let model = fixture.makeModel()

        model.edit("Board")
        await model.openTask?.value

        let line = TemplateOpenFailure.couldNotOpen(app: "TextEdit")
            .notShown(file: "Board.md", error: error.localizedDescription)
        XCTAssertEqual(model.notice, .warning(line))
    }
}
