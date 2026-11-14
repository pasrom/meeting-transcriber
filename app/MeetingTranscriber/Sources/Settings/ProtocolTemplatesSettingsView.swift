// Settings → Output → Meeting Notes Templates: the default template, one row per
// template file with the split button Edit and Delete, New Template… and Open
// Templates Folder. Templates open in the app the user chose last
// (`TemplateEditor`); the New Template window is `NewProtocolTemplateSheet`.

import AppKit
import Observation
import SwiftUI

/// What the Meeting Notes Templates section and its New Template window show, and
/// every write they make, held as a reference type so a test reads back the
/// object the view writes to (as with `SpeakerNamingRowState`,
/// docs/architecture/gui-testing.md).
///
/// Reads the folder through the store on `reload()`, never caches template
/// text, and never writes the migration marker, so a migration that failed
/// earlier still runs at the next launch.
@Observable
@MainActor
final class ProtocolTemplatesModel {
    static let builtInLabel = "Standard (built-in)"

    /// Template names in Finder's order, as of the last `reload()`.
    private(set) var names: [String] = []
    /// The line under New Template…, about the last action that went wrong;
    /// the next successful open, create, delete or folder open clears it.
    private(set) var notice: ProtocolTemplatesNotice?
    /// The template whose Delete was pressed and awaits confirmation.
    var pendingDeletion: String?

    /// Whether the New Template window is shown.
    var isNewTemplateShown = false
    /// What the window's Name field holds.
    var newTemplateName = "" {
        didSet { createError = nil }
    }

    /// Why the window's last Create failed; typing clears it.
    private(set) var createError: String?

    /// The open started last. Read by tests, which wait for it.
    @ObservationIgnored private(set) var openTask: Task<Void, Never>?

    private let store: ProtocolTemplateStore
    private let settings: AppSettings
    private let opener: TemplateOpener
    private let openFile: (URL) -> Void
    private let trashItem: (URL) throws -> Void

    /// `openFile` opens the templates folder; templates open through `opener`.
    init(
        store: ProtocolTemplateStore,
        settings: AppSettings,
        opener: TemplateOpener = .live,
        openFile: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        trashItem: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
    ) {
        self.store = store
        self.settings = settings
        self.opener = opener
        self.openFile = openFile
        self.trashItem = trashItem
    }

    /// The effective default as the folder lists it, so a setting naming a
    /// missing file shows the built-in instead of a blank picker. Setting it
    /// writes the setting.
    var defaultSelection: ProtocolTemplateID {
        get { listed(store.effectiveDefault(settings.defaultProtocolTemplate)) }
        set { settings.defaultProtocolTemplate = newValue }
    }

    /// The app Edit opens a template in.
    var editor: TemplateEditor {
        TemplateEditor.resolve(
            remembered: settings.templateEditorBundleIdentifier,
            installedApp: opener.installedApp,
            defaultApp: opener.defaultMarkdownApp,
        )
    }

    /// Every template's Open With submenu.
    var openWithEntries: [TemplateOpenWithEntry] {
        TemplateOpenWithEntry.entries(defaultApp: opener.defaultMarkdownApp(), offered: opener.markdownApps())
    }

    func reload() {
        names = store.names()
    }

    /// `id` spelt as the folder lists it. A Finder rename that changes only
    /// the case leaves the stored name resolving on a case-insensitive volume
    /// while matching no listed name, which would blank the picker.
    private func listed(_ id: ProtocolTemplateID) -> ProtocolTemplateID {
        guard case let .file(name) = id, !names.contains(name),
              let listedName = names.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return id }
        return .file(name: listedName)
    }

    func requestDelete(_ name: String) {
        pendingDeletion = name
    }

    /// Moves the template to the Trash. Deleting the default makes the
    /// built-in the default.
    func confirmDelete(_ name: String) {
        pendingDeletion = nil
        // Read before the file goes: afterwards the default no longer resolves.
        let deletesTheDefault = defaultSelection == .file(name: name)
        do {
            try store.trash(name: name, trashItem: trashItem)
            if deletesTheDefault {
                settings.defaultProtocolTemplate = .builtIn
            }
            notice = nil
        } catch {
            notice = .error(error.localizedDescription)
        }
        reload()
    }

    /// Creates the folder when it is missing, then opens it.
    func openFolder() {
        do {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            notice = nil
            openFile(store.directory)
        } catch {
            notice = .error(error.localizedDescription)
        }
    }

    // MARK: - New Template window

    func showNewTemplate() {
        newTemplateName = ""
        isNewTemplateShown = true
    }

    func cancelNewTemplate() {
        isNewTemplateShown = false
    }

    /// The store's refusal of the typed name against the folder as last
    /// listed, nil for an empty name, which only disables Create.
    var nameRefusal: String? {
        do {
            _ = try ProtocolTemplateName.validate(newTemplateName, existing: names)
            return nil
        } catch ProtocolTemplateName.Refusal.empty {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The red line under the Name field.
    var nameProblem: String? {
        createError ?? nameRefusal
    }

    var canCreate: Bool {
        (try? ProtocolTemplateName.validate(newTemplateName, existing: names)) != nil
    }

    /// The window's note for the name typed so far.
    var newTemplateNote: String {
        Self.newTemplateNote(name: newTemplateName)
    }

    /// The note for `typed`. It names no app: Create only writes the file, and
    /// Edit opens it in the editor app, as it does every template.
    static func newTemplateNote(name typed: String) -> String {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = name.isEmpty ? "a Markdown file" : "“\(name).md”"
        return "Creates \(file) in the templates folder from the built-in template. To change it, click Edit in "
            + "its row; the arrow beside Edit lets you pick the app."
    }

    /// Creates a template from the built-in text under the typed name and
    /// closes the window. It opens nothing: Edit opens the new row like any
    /// other, so a template never opens in one app on Create and another on
    /// Edit. The store checks the name against the folder again, so one taken
    /// since the window opened is refused; a refusal or a failed write keeps
    /// the window and the name.
    func createTemplate() {
        do {
            _ = try store.create(name: newTemplateName)
            isNewTemplateShown = false
            newTemplateName = ""
            notice = nil
            reload()
        } catch {
            reload()
            createError = error.localizedDescription
        }
    }

    // MARK: - Opening templates

    func edit(_ name: String) {
        openInEditor(store.fileURL(named: name))
    }

    /// Opens the template in `app` and makes it the editor app for every
    /// template.
    func openWith(_ app: TemplateEditorApp, template name: String) {
        settings.templateEditorBundleIdentifier = app.bundleIdentifier
        open(store.fileURL(named: name), in: app)
    }

    /// Asks for any app, then does what Open With does with it.
    func openWithOtherApp(template name: String) {
        guard let app = opener.chooseApp() else { return }
        openWith(app, template: name)
    }

    func showInFinder(_ name: String) {
        do {
            try opener.reveal(store.fileURL(named: name))
            notice = nil
        } catch {
            notice = .error(error.localizedDescription)
        }
    }

    private func openInEditor(_ file: URL) {
        switch editor {
        case let .app(app):
            open(file, in: app)

        case let .missing(bundleIdentifier):
            settings.templateEditorBundleIdentifier = nil
            showInFinder(file, because: .notFound(app: bundleIdentifier))

        case .noApp:
            showInFinder(file, because: .noApp)
        }
    }

    private func open(_ file: URL, in app: TemplateEditorApp) {
        openTask = Task {
            do {
                try await opener.open(file, app)
                notice = nil
            } catch {
                showInFinder(file, because: .couldNotOpen(app: app.name))
            }
        }
    }

    private func showInFinder(_ file: URL, because failure: TemplateOpenFailure) {
        let fileName = file.lastPathComponent
        do {
            try opener.reveal(file)
            notice = .warning(failure.shownInFinder(file: fileName))
        } catch {
            notice = .warning(failure.notShown(file: fileName, error: error.localizedDescription))
        }
    }
}

/// The line under New Template….
enum ProtocolTemplatesNotice: Equatable {
    /// A failed delete, folder open or Show in Finder, in red.
    case error(String)
    /// A template shown in Finder instead of opened, in orange with a warning icon.
    case warning(String)
}

/// The Meeting Notes Templates section. Rows and their controls are addressed by
/// row index, never by template name, because a name is user input and
/// `/ui/tree` publishes identifiers unredacted.
struct ProtocolTemplatesSettingsView: View {
    /// SwiftUI keeps the first object it is handed for the view's lifetime, so
    /// a test holds the object every control of this section writes to.
    @State private var model: ProtocolTemplatesModel

    init(model: ProtocolTemplatesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        let editor = model.editor
        Section("Meeting Notes Templates") {
            defaultPicker
            templateRows(editor: editor)
            actionsRow
            Text(editor.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Parts

    /// Also carries the section's reloads: the picker is always shown, so
    /// they run exactly once however many rows the section has.
    private var defaultPicker: some View {
        Picker("Default template", selection: $model.defaultSelection) {
            Text(ProtocolTemplatesModel.builtInLabel).tag(ProtocolTemplateID.builtIn)
            ForEach(model.names, id: \.self) { name in
                Text(name).tag(ProtocolTemplateID.file(name: name))
            }
        }
        .accessibilityIdentifier(A11yID.protocolTemplateDefaultPicker)
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }

    private func templateRows(editor: TemplateEditor) -> some View {
        let openWith = model.openWithEntries
        return ForEach(Array(model.names.enumerated()), id: \.element) { index, name in
            HStack {
                Text(name)
                Spacer()
                editButton(row: index, template: name, editor: editor, openWith: openWith)
                Button("Delete") { model.requestDelete(name) }
                    .accessibilityIdentifier(A11yID.protocolTemplateDelete(index))
                    .confirmationDialog(
                        "Move “\(name)” to the Trash?",
                        isPresented: deletionPrompt(for: name),
                        titleVisibility: .visible,
                    ) {
                        Button("Move to Trash", role: .destructive) { model.confirmDelete(name) }
                    }
            }
        }
    }

    /// Edit opens the template in the editor app; its arrow opens the menu.
    private func editButton(
        row: Int, template name: String, editor: TemplateEditor, openWith: [TemplateOpenWithEntry],
    ) -> some View {
        Menu {
            if let appName = editor.appName {
                Button("Open in \(appName)") { model.edit(name) }
                    .accessibilityIdentifier(A11yID.protocolTemplateOpenInEditor(row))
                Divider()
            }
            Menu("Open With") {
                openWithItems(row: row, template: name, entries: openWith)
            }
            Button("Show in Finder") { model.showInFinder(name) }
                .accessibilityIdentifier(A11yID.protocolTemplateShowInFinder(row))
        } label: {
            Text("Edit")
        } primaryAction: {
            model.edit(name)
        }
        .fixedSize()
        .accessibilityIdentifier(A11yID.protocolTemplateEdit(row))
    }

    private func openWithItems(row: Int, template name: String, entries: [TemplateOpenWithEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { position, entry in
            switch entry {
            case let .app(app, title):
                Button(title) { model.openWith(app, template: name) }
                    .accessibilityIdentifier(A11yID.protocolTemplateOpenWithApp(row, position))

            case .separator:
                Divider()

            case .other:
                Button(TemplateOpenWithEntry.otherTitle) { model.openWithOtherApp(template: name) }
                    .accessibilityIdentifier(A11yID.protocolTemplateOpenWithOther(row))
            }
        }
    }

    private var actionsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    model.showNewTemplate()
                } label: {
                    Label("New Template…", systemImage: "plus")
                }
                .accessibilityIdentifier(A11yID.protocolTemplateNewButton)
                .sheet(isPresented: $model.isNewTemplateShown) {
                    NewProtocolTemplateSheet(model: model)
                }
                Button("Open Templates Folder") { model.openFolder() }
                    .accessibilityIdentifier(A11yID.protocolTemplatesOpenFolderButton)
            }
            noticeLine
        }
    }

    @ViewBuilder private var noticeLine: some View {
        switch model.notice {
        case let .error(text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.red)

        case let .warning(text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

        case nil:
            EmptyView()
        }
    }

    /// Presented while `name` awaits confirmation. The button passes its own
    /// row's name, so the action does not depend on whether SwiftUI clears the
    /// binding before or after running it.
    private func deletionPrompt(for name: String) -> Binding<Bool> {
        Binding(
            get: { model.pendingDeletion == name },
            set: { presented in
                if !presented, model.pendingDeletion == name { model.pendingDeletion = nil }
            },
        )
    }
}
