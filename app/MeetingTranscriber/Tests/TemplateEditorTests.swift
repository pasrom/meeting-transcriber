@testable import MeetingTranscriber
import XCTest

/// Which app a template opens in, the Open With list, and the lines the
/// templates section shows when a template goes to Finder instead.
@MainActor
final class TemplateEditorTests: XCTestCase {
    private typealias Fake = FakeTemplateOpener

    private func resolve(
        remembered: String?, installed: [TemplateEditorApp], defaultApp: TemplateEditorApp?,
    ) -> TemplateEditor {
        TemplateEditor.resolve(
            remembered: remembered,
            installedApp: { id in installed.first { $0.bundleIdentifier == id } },
            defaultApp: { defaultApp },
        )
    }

    // MARK: - Choosing the app

    /// Typora was picked under Other… and is not among the apps macOS offers
    /// for Markdown files; it is still the editor.
    func testARememberedInstalledAppIsTheEditor() {
        let editor = resolve(remembered: Fake.typora.bundleIdentifier, installed: [Fake.typora], defaultApp: Fake.textEdit)

        XCTAssertEqual(editor, .app(Fake.typora))
    }

    /// Edit shows the template in Finder, so nothing offers to open it in the
    /// missing app; the bundle identifier names it in the reason.
    func testARememberedAppThatIsGoneIsMissing() {
        let editor = resolve(remembered: Fake.typora.bundleIdentifier, installed: [Fake.textEdit], defaultApp: Fake.textEdit)

        XCTAssertEqual(editor, .missing(bundleIdentifier: Fake.typora.bundleIdentifier))
        XCTAssertNil(editor.appName)
        XCTAssertTrue(editor.helpText.contains("Edit shows one in Finder, as abnerworks.Typora was not found."))
    }

    func testWithNothingRememberedTheDefaultAppIsTheEditor() {
        XCTAssertEqual(resolve(remembered: nil, installed: [Fake.textEdit], defaultApp: Fake.textEdit), .app(Fake.textEdit))
    }

    func testWithNothingRememberedAndNoDefaultAppTheFileGoesToFinder() {
        let editor = resolve(remembered: nil, installed: [Fake.textEdit], defaultApp: nil)

        XCTAssertEqual(editor, .noApp)
        XCTAssertNil(editor.appName)
    }

    // MARK: - Open With

    func testOpenWithListsTheDefaultFirstThenTheOthersByNameEachOnceThenOther() {
        let entries = TemplateOpenWithEntry.entries(
            defaultApp: Fake.textEdit,
            offered: [Fake.code, Fake.textEdit, Fake.typora, Fake.app("Typora", Fake.typora.bundleIdentifier)],
        )

        XCTAssertEqual(entries, [
            .app(Fake.textEdit, title: "TextEdit (default)"),
            .app(Fake.typora, title: "Typora"),
            .app(Fake.code, title: "Visual Studio Code"),
            .separator,
            .other,
        ])
    }

    func testOpenWithWithoutAnyAppListsOnlyOther() {
        XCTAssertEqual(TemplateOpenWithEntry.entries(defaultApp: nil, offered: []), [.other])
    }

    // MARK: - Wording

    func testTheHelpTextNamesTheEditorApp() {
        let editor = TemplateEditor.app(Fake.textEdit)

        XCTAssertEqual(editor.helpText, """
        Templates are Markdown files in the templates folder. Edit opens one in TextEdit. To use another app, click \
        the arrow beside Edit and choose Open With; the app remembers your choice. {LANGUAGE}, {MEETING_DATE} and \
        {MEETING_TIME} are filled in for every template.
        """)
    }

    func testWithoutAnAppTheHelpTextSaysTheFileIsShownInFinder() {
        XCTAssertTrue(TemplateEditor.noApp.helpText.contains(
            "Edit shows one in Finder, as no app is set to open Markdown files.",
        ))
    }

    func testEachReasonHasItsLineWhetherOrNotFinderShowsTheFile() {
        let cases: [(TemplateOpenFailure, shown: String, notShown: String)] = [
            (
                .couldNotOpen(app: "Typora"),
                "Typora could not open “Board.md”, so it is shown in Finder. "
                    + "Open it from there with any app, or choose another app under Open With.",
                "Typora could not open “Board.md”, and Finder could not show it either: No such file.",
            ),
            (
                .notFound(app: "abnerworks.Typora"),
                "abnerworks.Typora was not found, so “Board.md” is shown in Finder. "
                    + "Open it from there with any app, or choose another app under Open With.",
                "abnerworks.Typora was not found, and Finder could not show “Board.md” either: No such file.",
            ),
            (
                .noApp,
                "No app is set to open Markdown files, so “Board.md” is shown in Finder. "
                    + "Open it from there with any app, or choose an app under Open With.",
                "No app is set to open Markdown files, and Finder could not show “Board.md” either: No such file.",
            ),
        ]
        for (failure, shown, notShown) in cases {
            XCTAssertEqual(failure.shownInFinder(file: "Board.md"), shown)
            XCTAssertEqual(failure.notShown(file: "Board.md", error: "No such file."), notShown)
        }
    }
}
