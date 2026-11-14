// Which app a meeting-notes template opens in, the Open With list, and the words
// the templates section uses for both. Pure values, so the choices are tested
// without an app, a window or a file.

import Foundation

/// The app Edit opens a template in: the one last chosen under Open With or
/// Other…, else the Mac's default app for Markdown files.
enum TemplateEditor: Equatable {
    case app(TemplateEditorApp)
    /// The remembered app is no longer installed: the file is shown in Finder
    /// and the app is forgotten.
    case missing(bundleIdentifier: String)
    /// Nothing is remembered and no app opens Markdown files: the file is shown
    /// in Finder.
    case noApp

    /// The remembered app is looked up by its bundle identifier alone, never in
    /// the Markdown list, so an app picked under Other… that macOS does not
    /// offer for Markdown files stays the editor.
    static func resolve(
        remembered: String?,
        installedApp: (String) -> TemplateEditorApp?,
        defaultApp: () -> TemplateEditorApp?,
    ) -> Self {
        if let remembered {
            return installedApp(remembered).map { .app($0) } ?? .missing(bundleIdentifier: remembered)
        }
        return defaultApp().map { .app($0) } ?? .noApp
    }

    /// The app Edit opens templates in, named by the menu's "Open in" item;
    /// nil when they are shown in Finder.
    var appName: String? {
        if case let .app(app) = self { app.name } else { nil }
    }

    /// Why Edit shows templates in Finder, for `.missing` and `.noApp`. A
    /// missing app has no name left to ask for, so its bundle identifier
    /// stands in, as in `MicInputDetector.appDisplayName`.
    private var finderReason: String {
        if case let .missing(bundleIdentifier) = self {
            "\(bundleIdentifier) was not found"
        } else {
            "no app is set to open Markdown files"
        }
    }

    /// The help text under the templates section.
    var helpText: String {
        let opening = switch self {
        case let .app(app):
            "Edit opens one in \(app.name). To use another app, click the arrow beside Edit and choose Open With; "
                + "the app remembers your choice."

        case .missing, .noApp:
            "Edit shows one in Finder, as \(finderReason). To use an app, click the arrow beside Edit and choose "
                + "Open With; the app remembers your choice."
        }
        return "Templates are Markdown files in the templates folder. \(opening) {LANGUAGE}, {MEETING_DATE} and "
            + "{MEETING_TIME} are filled in for every template."
    }
}

/// One line of a template's Open With submenu.
enum TemplateOpenWithEntry: Hashable {
    case app(TemplateEditorApp, title: String)
    case separator
    case other

    static let otherTitle = "Other…"

    /// The default app first, marked "(default)", then the other apps macOS
    /// offers by name, each app once, then "Other…".
    static func entries(defaultApp: TemplateEditorApp?, offered: [TemplateEditorApp]) -> [Self] {
        var apps: [Self] = []
        var listed: Set<String> = []
        if let defaultApp {
            apps.append(.app(defaultApp, title: "\(defaultApp.name) (default)"))
            listed.insert(defaultApp.bundleIdentifier)
        }
        var others: [TemplateEditorApp] = []
        for app in offered where listed.insert(app.bundleIdentifier).inserted {
            others.append(app)
        }
        others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        apps += others.map { .app($0, title: $0.name) }
        return apps.isEmpty ? [.other] : apps + [.separator, .other]
    }
}

/// Why a template was shown in Finder instead of opened, and the orange line
/// under New Template… that says so.
enum TemplateOpenFailure: Equatable {
    case couldNotOpen(app: String)
    case notFound(app: String)
    case noApp

    /// The line once Finder shows `file` (a file name, extension included).
    func shownInFinder(file: String) -> String {
        switch self {
        case let .couldNotOpen(app):
            "\(app) could not open “\(file)”, so it is shown in Finder. "
                + "Open it from there with any app, or choose another app under Open With."

        case let .notFound(app):
            "\(app) was not found, so “\(file)” is shown in Finder. "
                + "Open it from there with any app, or choose another app under Open With."

        case .noApp:
            "No app is set to open Markdown files, so “\(file)” is shown in Finder. "
                + "Open it from there with any app, or choose an app under Open With."
        }
    }

    /// The line when Finder could not show `file` either, naming Finder's error.
    func notShown(file: String, error: String) -> String {
        switch self {
        case let .couldNotOpen(app):
            "\(app) could not open “\(file)”, and Finder could not show it either: \(error)"

        case let .notFound(app):
            "\(app) was not found, and Finder could not show “\(file)” either: \(error)"

        case .noApp:
            "No app is set to open Markdown files, and Finder could not show “\(file)” either: \(error)"
        }
    }
}
