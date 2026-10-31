import AppKit
import SwiftUI

/// Notion database export configuration. Split out of `OutputSettingsView`
/// so the connection, schema-check, and database-creation state has one home.
struct NotionExportSettingsView: View {
    @Bindable var settings: AppSettings

    /// A StateObject because it takes its value lazily: the parent re-creates
    /// this view on every settings change, and the model's init reads the Keychain.
    @StateObject private var model: NotionExportSettingsModel
    @FocusState private var apiKeyFocused: Bool

    // swiftlint:disable:next unneeded_escaping
    init(settings: AppSettings, model: @autoclosure @escaping () -> NotionExportSettingsModel? = nil) {
        self.settings = settings
        _model = StateObject(wrappedValue: model() ?? NotionExportSettingsModel(settings: settings))
    }

    var body: some View {
        Section {
            Toggle("Export to Notion Database", isOn: $settings.notionExportEnabled)
                .accessibilityIdentifier(A11yID.notionExportToggle)

            if settings.notionExportEnabled {
                if let notice = model.configurationNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(A11yID.notionConfigurationNotice)
                }
                notionConfigView
            }
        } header: {
            HStack(spacing: 4) {
                Text("Notion Database Export")
                    .accessibilityIdentifier(A11yID.notionSection)
                HelpBadge(text: SettingsHelp.notionExport, systemImage: "questionmark.circle")
            }
        }
        .recordOnlyDisabled(settings.recordOnly)
        .task {
            if model.isNotionConnected { await model.refresh(silent: true) }
        }
        .onDisappear { model.commitAPIKey() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            model.settingsWindowWillClose(notification)
        }
        .onChange(of: settings.notionExportEnabled) { _, isEnabled in
            if isEnabled && model.hasAPIKey && model.availableDatabases.isEmpty {
                Task { await model.refresh(silent: true) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshAfterActivation() }
        }
    }
}

private extension NotionExportSettingsView {
    // MARK: - Notion Export Views & Logic

    @ViewBuilder private var notionConfigView: some View {
        SecureField("API Token", text: $model.apiKeyDraft, prompt: Text("ntn_... or secret_..."))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .accessibilityIdentifier(A11yID.notionAPIKeyField)
            .focused($apiKeyFocused)
            .onSubmit { model.commitAPIKey() }
            .onChange(of: apiKeyFocused) { _, focused in
                if !focused { model.commitAPIKey() }
            }
            .onDisappear { model.commitAPIKey() }

        HStack {
            Button {
                model.commitAPIKey()
                Task { await model.refresh() }
            } label: {
                HStack(spacing: 4) {
                    if model.testingNotion {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Test Connection")
                }
            }
            .disabled(model.testingNotion || !model.hasAPIKey)
            .accessibilityIdentifier(A11yID.notionTestConnectionButton)

            if let result = model.notionStatusResult {
                switch result {
                case let .success(message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)

                case let .failure(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            Spacer()
        }

        if model.isNotionConnected {
            notionDatabaseSelectionRow
            if model.needsDatabaseConfirmation {
                Button("Use This Database") { model.confirmDatabase() }
                    .accessibilityIdentifier(A11yID.notionConfirmDatabaseButton)
                Text("Confirm this database to start exporting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.selectedDatabaseTag != NotionExportSettingsModel.createDatabaseTag && model.selectedDatabaseTag != NotionExportSettingsModel
                .customDatabaseTag {
                databaseSchemaStatusView
            }

            if model.selectedDatabaseTag == NotionExportSettingsModel.createDatabaseTag {
                notionCreateDatabaseSubView
            } else if model.selectedDatabaseTag == NotionExportSettingsModel.customDatabaseTag {
                notionCustomDatabaseSubView
            }
        }

        Toggle("Skip local markdown file on success", isOn: $settings.notionSkipLocalMarkdownOnSuccess)
            .accessibilityIdentifier(A11yID.notionSkipLocalMarkdownToggle)
        Toggle("Include speaker names as tags", isOn: $settings.notionSpeakerTagsEnabled)
            .accessibilityIdentifier(A11yID.notionSpeakerTagsToggle)
        Text("Adds confirmed speaker names to the database’s Tags column.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var notionDatabaseSelectionRow: some View {
        HStack {
            Picker("Database", selection: Binding(
                get: { model.selectedDatabaseTag },
                set: { tag in
                    model.selectDatabase(tag)
                    Task { await model.checkDatabaseSchema(id: model.databaseInput) }
                },
            )) {
                Text("+ Create \"Meeting Transcriber\" Database")
                    .tag(NotionExportSettingsModel.createDatabaseTag)

                ForEach(model.availableDatabases) { db in
                    Text(databaseLabel(for: db)).tag(db.id)
                }

                Text("Custom Database ID or URL\u{2026}")
                    .tag(NotionExportSettingsModel.customDatabaseTag)
            }
            .accessibilityIdentifier(A11yID.notionDatabasePicker)

            Button {
                model.commitAPIKey()
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!model.hasAPIKey || model.testingNotion)
            .accessibilityIdentifier(A11yID.notionRefreshButton)
            .help("Refresh databases from Notion")
            .accessibilityLabel("Refresh Notion databases")

            if model.testingNotion {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// Two active databases can share a title. Append a short ID only when
    /// that happens, so the picker can tell them apart without cluttering
    /// the usual single-database case.
    private func databaseLabel(for database: NotionDatabaseItem) -> String {
        let duplicates = model.availableDatabases.filter { $0.title == database.title }
        guard duplicates.count > 1 else { return database.title }
        return "\(database.title) (\(database.id.prefix(8)))"
    }

    @ViewBuilder private var databaseSchemaStatusView: some View {
        if model.checkingSchema {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking database columns\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else if let error = model.schemaCheckError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.vertical, 2)
        } else if let status = model.databaseSchemaStatus {
            if status.hasAllOptionalColumns {
                Label(
                    model
                        .needsDatabaseConfirmation ? "Compatible database — confirm to start exporting." :
                        "Ready to export — title, tags, and date columns matched.",
                    systemImage: "checkmark.circle.fill",
                )
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        (model.needsDatabaseConfirmation ? "Compatible database. Optional column" : "Ready to export. Optional column")
                            + "\(status.missingColumns.count == 1 ? "" : "s") missing: "
                            + status.missingColumns.joined(separator: ", "),
                        systemImage: "info.circle.fill",
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            Task { await model.upgradeDatabaseSchema() }
                        } label: {
                            HStack(spacing: 4) {
                                if model.upgradingSchema {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("Add Optional Columns to Notion Database")
                            }
                        }
                        .disabled(model.upgradingSchema)
                        .accessibilityIdentifier(A11yID.notionUpgradeSchemaButton)
                        Spacer()
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var notionCreateDatabaseSubView: some View {
        // swiftlint:disable:next closure_body_length
        VStack(alignment: .leading, spacing: 6) {
            Text("New databases are created as a subpage of a page shared with your Notion integration.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.availablePages.isEmpty {
                Picker("Parent Page", selection: $model.selectedParentPageID) {
                    Text("Choose a page\u{2026}").tag("")
                    ForEach(model.availablePages) { page in
                        Text(page.title).tag(page.id)
                    }
                    Text("Enter Page URL / ID manually\u{2026}").tag(NotionExportSettingsModel.manualParentTag)
                }
                .accessibilityIdentifier(A11yID.notionParentPagePicker)
            }

            if model.availablePages.isEmpty || model.selectedParentPageID == NotionExportSettingsModel.manualParentTag {
                TextField(
                    "Parent Page",
                    text: $model.manualParentPageInput,
                    prompt: Text("Notion page URL or 32-character ID"),
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .accessibilityIdentifier(A11yID.notionParentPageField)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.createDatabase() }
                } label: {
                    HStack(spacing: 4) {
                        if model.isCreatingDatabase {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Create Database in Notion")
                    }
                }
                .disabled(model.isCreatingDatabase || !model.isParentPageAvailable || !model.hasAPIKey)
                .accessibilityIdentifier(A11yID.notionInitDatabaseButton)

                Spacer()
            }

            if let error = model.createDatabaseError {
                Label(error, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var notionCustomDatabaseSubView: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Database ID or URL", text: Binding(
                get: { model.manualDatabaseIDInput },
                set: { value in
                    model.setManualDatabaseInput(value)
                    Task { await model.checkDatabaseSchema(id: value) }
                },
            ), prompt: Text("32-character ID or database URL"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .accessibilityIdentifier(A11yID.notionDatabaseIDField)

            databaseSchemaStatusView
        }
        .padding(.vertical, 4)
    }
}
