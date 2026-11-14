import Foundation
@testable import MeetingTranscriber

/// A `TemplateOpener` that answers from its properties and records what the
/// templates section asked for, so no test launches an app, shows a panel or
/// reveals a file.
@MainActor
final class FakeTemplateOpener {
    struct OpenFailure: Error {}

    /// A file opened in the app with this bundle identifier.
    struct Opened: Equatable {
        let file: URL
        let app: String
    }

    static let textEdit = app("TextEdit", "com.apple.TextEdit")
    static let code = app("Visual Studio Code", "com.microsoft.VSCode")
    static let typora = app("Typora", "abnerworks.Typora")

    static func app(_ name: String, _ bundleIdentifier: String) -> TemplateEditorApp {
        TemplateEditorApp(
            bundleIdentifier: bundleIdentifier, url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name,
        )
    }

    /// The Mac's default app for Markdown files.
    var defaultApp: TemplateEditorApp? = textEdit
    /// The apps macOS offers for Markdown files.
    var offered: [TemplateEditorApp] = [textEdit, code]
    /// Every installed app, by bundle identifier.
    var installed: [TemplateEditorApp] = [textEdit, code, typora]
    /// Apps whose open throws.
    var failing: Set<String> = []
    /// What a reveal throws; nil reveals.
    var revealError: (any Error)?
    /// What the app picker answers.
    var chosen: TemplateEditorApp?

    private(set) var opened: [Opened] = []
    private(set) var revealed: [URL] = []
    private(set) var pickerShown = 0

    var opener: TemplateOpener {
        TemplateOpener(
            defaultMarkdownApp: { self.defaultApp },
            markdownApps: { self.offered },
            installedApp: { id in self.installed.first { $0.bundleIdentifier == id } },
            open: { file, app in
                if self.failing.contains(app.bundleIdentifier) { throw OpenFailure() }
                self.opened.append(Opened(file: file, app: app.bundleIdentifier))
            },
            reveal: { file in
                if let error = self.revealError { throw error }
                self.revealed.append(file)
            },
            chooseApp: {
                self.pickerShown += 1
                return self.chosen
            },
        )
    }
}
