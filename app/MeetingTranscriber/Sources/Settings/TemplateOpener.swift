// How Settings → Output → Meeting Notes Templates reaches the Mac when it opens a
// template: the apps macOS offers for Markdown files, an app by its bundle
// identifier, opening a file in an app, Finder, and the app picker. The section
// goes through `TemplateOpener` alone, so its tests inject a fake and never
// launch an app, show a panel or reveal a file.

import AppKit
import UniformTypeIdentifiers

/// An app a template can be opened in.
struct TemplateEditorApp: Hashable {
    /// What the app is remembered by (`AppSettings.templateEditorBundleIdentifier`).
    let bundleIdentifier: String
    let url: URL
    /// The app's name as Finder shows it, without ".app".
    let name: String
}

extension TemplateEditorApp {
    /// The app at `url`; nil when it has no bundle identifier to be remembered by.
    init?(appAt url: URL) {
        guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return nil }
        let shown = FileManager.default.displayName(atPath: url.path)
        let name = shown.hasSuffix(".app") ? String(shown.dropLast(".app".count)) : shown
        self.init(bundleIdentifier: bundleIdentifier, url: url, name: name)
    }
}

/// The operations the templates section needs from the Mac. `live` wraps
/// `NSWorkspace` and `NSOpenPanel`.
@MainActor
struct TemplateOpener {
    /// The Mac's default app for Markdown files.
    var defaultMarkdownApp: () -> TemplateEditorApp?
    /// The apps macOS offers for Markdown files.
    var markdownApps: () -> [TemplateEditorApp]
    /// The installed app with this bundle identifier.
    var installedApp: (_ bundleIdentifier: String) -> TemplateEditorApp?
    /// Opens the file in the app; throws when the app could not open it.
    var open: (_ file: URL, _ app: TemplateEditorApp) async throws -> Void
    /// Shows the file selected in Finder; throws when Finder could not.
    var reveal: (_ file: URL) throws -> Void
    /// Asks the user to pick an app; nil when the panel was cancelled.
    var chooseApp: () -> TemplateEditorApp?
}

extension TemplateOpener {
    /// Markdown by the content type of the `.md` extension, never by a file's
    /// URL: the section names the app before any template file exists, and a
    /// URL lookup finds no app for a file that is not there.
    private static let markdown = UTType(filenameExtension: "md") ?? .plainText

    static var live: Self {
        Self(
            defaultMarkdownApp: {
                NSWorkspace.shared.urlForApplication(toOpen: markdown).flatMap(TemplateEditorApp.init(appAt:))
            },
            markdownApps: {
                NSWorkspace.shared.urlsForApplications(toOpen: markdown).compactMap(TemplateEditorApp.init(appAt:))
            },
            installedApp: { bundleIdentifier in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
                    .flatMap(TemplateEditorApp.init(appAt:))
            },
            open: { file, app in
                _ = try await NSWorkspace.shared.open(
                    [file], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration(),
                )
            },
            reveal: { file in
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: file.path])
                }
                guard NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "") else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: file.path])
                }
            },
            chooseApp: {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.application]
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                guard panel.runModal() == .OK, let url = panel.url else { return nil }
                return TemplateEditorApp(appAt: url)
            },
        )
    }
}
