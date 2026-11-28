import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "OutputSettingsView")

/// Pure derivations used by `OutputSettingsView`. Extracted so the wrapping
/// logic can be unit-tested without instantiating a SwiftUI host.
enum OutputSettingsLogic {
    /// Install `source` as the custom prompt at `dest`, replacing any prompt
    /// already there. The picked file is the user's and must survive.
    static func importPrompt(from source: URL, to dest: URL) throws {
        // Read and write rather than `replaceItemAt`, which moves the
        // replacement into place and so removed the file the user picked.
        try Data(contentsOf: source).write(to: dest, options: .atomic)
    }

    /// Abbreviate `url` for display by replacing the home-directory prefix
    /// with `~` so paths inside the user's home stay compact. Falls back to
    /// the full path when `url` is outside `home`. Matches at the path-
    /// component boundary so `home="/Users/alice"` doesn't abbreviate
    /// `/Users/alicebob/...` to `~bob/...`.
    static func displayPath(for url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        let prefixed = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(prefixed) else { return path }
        return "~/" + path.dropFirst(prefixed.count)
    }

    /// Merge the currently-selected value into a picker list so the user's
    /// choice survives even when the list doesn't contain it: a model that
    /// `/models` doesn't echo back (custom Ollama tags, in-flight rename,
    /// offline cache), or a protocol language stored by an older build or set
    /// outside the app. Returns `available` unchanged when `selected` is empty
    /// or already present.
    static func mergePickerOptions(available: [String], selected: String) -> [String] {
        guard !selected.isEmpty, !available.contains(selected) else { return available }
        return [selected] + available
    }

    /// Why the FLAC toggle is disabled, or nil while it may be used. Only a
    /// probe that found no FLAC disables it; one still running does not.
    static func flacUnavailableReason(_ status: KeptRecordingCodecStatus) -> String? {
        status.unavailableReason.map { "FLAC cannot be written on this Mac (\($0)), so recordings stay WAV." }
    }

    /// The retention period as the Settings row shows it. Zero is spelled out,
    /// since "0 days" alone reads like "never".
    static func retentionDaysLabel(_ days: Int) -> String {
        switch days {
        case ...0: "0 days (right away)"
        case 1: "1 day"
        default: "\(days) days"
        }
    }
}

enum ConnectionTestResult {
    case success(String)
    case failure(String)
}

struct OutputSettingsView: View {
    @Bindable var settings: AppSettings

    #if !APPSTORE
        @State private var claudeBinaries: [String] = ["claude"]
    #endif
    @State private var testingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var availableModels: [String] = []
    @State private var didAttemptConnectionTest = false
    @State private var showResetPromptConfirmation = false
    @State private var hasCustomPrompt = false
    static let fieldWidth: CGFloat = 260
    /// The API key fields type into these, not into the Keychain.
    @StateObject private var apiKeyDrafts: ProtocolAPIKeyDrafts

    /// What the launch probe found; the FLAC toggle is disabled, with the
    /// reason, when this Mac cannot write FLAC.
    let keptRecordingCodec: KeptRecordingCodecStatus
    /// The "Compress Existing Recordings" rows; nil leaves them out, which is
    /// what tests of other rows get.
    let compressExisting: CompressExistingRecordingsState?

    init(
        settings: AppSettings,
        keptRecordingCodec: KeptRecordingCodecStatus = .unknown,
        compressExisting: CompressExistingRecordingsState? = nil,
        // swiftlint:disable:next unneeded_escaping
        apiKeyDrafts: @autoclosure @escaping () -> ProtocolAPIKeyDrafts? = nil,
    ) {
        self.settings = settings
        self.keptRecordingCodec = keptRecordingCodec
        self.compressExisting = compressExisting
        _apiKeyDrafts = StateObject(wrappedValue: apiKeyDrafts() ?? ProtocolAPIKeyDrafts(settings: settings))
    }

    var body: some View {
        Form {
            // Output folder applies to record-only AND protocol mode, so this
            // section deliberately sits outside the .recordOnlyDisabled block.
            Section("Output Folder") {
                HStack {
                    Text("Output Folder")
                    Spacer()
                    Text(outputDirDisplay)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button("Choose\u{2026}") {
                        chooseOutputFolder()
                    }

                    Button("Reset") {
                        settings.clearCustomOutputDir()
                    }
                    .disabled(settings.customOutputDirBookmark == nil)

                    Spacer()
                }
            }
            .accessibilityIdentifier(A11yID.outputFolderSection)

            NotionExportSettingsView(settings: settings)

            // Outside the record-only block as well: entries recorded before
            // record-only was switched on are still swept, and record-only
            // output itself is never recorded, so the setting cannot reach it.
            recordingSections

            meetingNotesSection
            providerSection

            if settings.protocolProvider == .openAICompatible {
                OpenAIConnectionSection(settings: settings, apiKeyDrafts: apiKeyDrafts)
                    .accessibilityIdentifier(A11yID.openAIConnectionSection)
                    .recordOnlyDisabled(settings.recordOnly)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            #if !APPSTORE
                claudeBinaries = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            #endif
            refreshCustomPromptState()
        }
        // A hidden Settings window and a quit reach neither a focus change nor
        // `onDisappear`, so an edited key is handed over here as well.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            apiKeyDrafts.settingsWindowWillClose(notification, settings: settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            apiKeyDrafts.commitPending(to: settings)
        }
    }

    private var meetingNotesSection: some View {
        Section("Meeting Notes") {
            Picker("Notes Language", selection: $settings.protocolLanguage) {
                ForEach(languagePickerOptions, id: \.self) { lang in
                    Text(lang).tag(lang)
                }
            }

            if settings.protocolProvider != .none {
                promptControls
            }

            Toggle("Include full transcript", isOn: $settings.includeFullTranscriptInProtocol)
                .accessibilityIdentifier(A11yID.includeFullTranscriptToggle)
            Toggle("Save raw transcript separately", isOn: $settings.saveRawTranscriptSeparately)
                .accessibilityIdentifier(A11yID.saveRawTranscriptToggle)
            Toggle("Name files with AI meeting title", isOn: $settings.useAITitleForFilenames)
                .accessibilityIdentifier(A11yID.useAITitleForFilenamesToggle)
            Toggle("Notify when meeting notes fail", isOn: $settings.notifyOnMeetingNotesFailure)
                .accessibilityIdentifier(A11yID.notifyOnMeetingNotesFailureToggle)
        }
        .accessibilityIdentifier(A11yID.protocolSection)
        .recordOnlyDisabled(settings.recordOnly)
    }

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $settings.protocolProvider) {
                ForEach(ProtocolProvider.allCases, id: \.self) { provider in
                    Text(provider.label).tag(provider)
                }
            }

            providerConfigView
        } header: {
            HStack(spacing: 4) {
                Text("AI Provider")
                HelpBadge(text: providerHelp, systemImage: "questionmark.circle")
            }
        }
        .accessibilityIdentifier(A11yID.protocolProviderSection)
        .recordOnlyDisabled(settings.recordOnly)
    }

    /// Storage first: retention deletes what storage keeps.
    @ViewBuilder
    private var recordingSections: some View { // swiftlint:disable:this attributes
        recordingStorageSection
        recordingRetentionSection
    }

    private var recordingStorageSection: some View {
        let unavailable = OutputSettingsLogic.flacUnavailableReason(keptRecordingCodec)
        return Section("Recording Storage") {
            Toggle("Store recordings as FLAC (lossless)", isOn: $settings.compressKeptRecordings)
                .accessibilityIdentifier(A11yID.compressKeptRecordingsToggle)
                // Still switchable off when it was on before FLAC went away.
                .disabled(unavailable != nil && !settings.compressKeptRecordings)

            if let reason = unavailable {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(A11yID.compressKeptRecordingsUnavailable)
            }

            Text(
                "After a meeting is processed, its recording in the output folder's recordings folder is converted "
                    + "to FLAC: _mix.flac, _app.flac and _mic.flac instead of the .wav files, smaller and with "
                    + "exactly the same audio. Each file is checked against its WAV before the "
                    + "WAV is removed. Recordings made before this was switched on, imported files and "
                    + "record-only recordings stay as they are. Older versions of the app do not pair FLAC "
                    + "tracks when they are imported again.",
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let compressExisting {
                CompressExistingRecordingsRows(state: compressExisting)
            }
        }
    }

    private var recordingRetentionSection: some View {
        Section("Recording Retention") {
            Toggle("Delete recordings after processing", isOn: $settings.recordingRetentionEnabled)
                .accessibilityIdentifier(A11yID.recordingRetentionToggle)

            HStack {
                Text("Keep recordings for")
                Spacer()
                Text(OutputSettingsLogic.retentionDaysLabel(settings.recordingRetentionDays))
                    .foregroundStyle(.secondary)
                Stepper("", value: $settings.recordingRetentionDays, in: 0 ... 3650)
                    .labelsHidden()
                    .accessibilityIdentifier(A11yID.recordingRetentionDaysStepper)
            }
            .disabled(!settings.recordingRetentionEnabled)

            Text(
                "Counted from the recording date. A recording is deleted only after its meeting notes were saved, "
                    + "or its transcript when no LLM provider is set. A recording waiting for speaker names is kept "
                    + "until they are given or skipped, or the naming wait set under Speakers runs out. "
                    + "Only audio this app recorded and moved into "
                    + "the output folder is affected: imported files, record-only recordings and recordings "
                    + "processed by earlier versions are never deleted. Switching this on, or shortening the "
                    + "period, deletes the recordings already past it.",
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            RecordingStorageLimitRows(settings: settings)
        }
    }

    @ViewBuilder
    private var providerConfigView: some View { // swiftlint:disable:this attributes
        switch settings.protocolProvider {
        #if !APPSTORE
            case .claudeCLI:
                Picker("Claude CLI", selection: $settings.claudeBin) {
                    ForEach(claudeBinaries, id: \.self) { bin in
                        Text(bin).tag(bin)
                    }
                }

                HStack {
                    Text("API Key")
                    Spacer()
                    DraftTextField("", value: apiKeyDrafts.savedClaude, draft: $apiKeyDrafts.claude, secure: true) { key in
                        apiKeyDrafts.commitClaude(key, to: settings)
                    }
                    .frame(width: Self.fieldWidth)
                    .accessibilityIdentifier(A11yID.claudeAPIKeyField)
                }

                // In view rather than in the help popover: it is what saves a surprise bill.
                Text("A key set here is billed separately from your subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(A11yID.claudeAPIKeyBillingNote)
        #endif

        case .openAICompatible:
            OpenAIConnectionControls(settings: settings, switchConnection: switchConnection)
            modelRow

        case .none:
            EmptyView()
        }
    }

    private var providerHelp: String {
        switch settings.protocolProvider {
        #if !APPSTORE
            case .claudeCLI: SettingsHelp.claudeCLIProvider
        #endif

        case .openAICompatible: SettingsHelp.openAIProvider

        case .none: SettingsHelp.noProvider
        }
    }

    private var modelRow: some View {
        HStack {
            if !availableModels.isEmpty {
                Picker(selection: $settings.openAIModel) {
                    ForEach(modelPickerOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                } label: {
                    modelLabel
                }
            } else {
                modelLabel
                Spacer()
                TextField("", text: $settings.openAIModel)
                    .frame(width: Self.fieldWidth)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(A11yID.openAIModelField)
            }

            let fetchTitle = availableModels.isEmpty ? "Fetch Models" : "Refresh Models"
            Button {
                testConnection()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(testingConnection)
            .help(fetchTitle)
            .accessibilityLabel(fetchTitle)
            .accessibilityIdentifier(A11yID.openAIRefreshModelsButton)
        }
        .onAppear {
            if availableModels.isEmpty && !didAttemptConnectionTest {
                testConnection()
            }
        }
    }

    private var modelLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Model")
            if testingConnection {
                Text("Checking\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let result = connectionTestResult {
                switch result {
                case let .success(msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)

                case let .failure(msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var promptControls: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prompt")
                Text(hasCustomPrompt ? "Using custom prompt" : "Using default prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Edit\u{2026}") {
                openCustomPrompt()
                refreshCustomPromptState()
            }

            Menu {
                Button("Import Prompt\u{2026}") {
                    importCustomPrompt()
                    refreshCustomPromptState()
                }
                Button("Reset to Default\u{2026}") {
                    showResetPromptConfirmation = true
                }
                .disabled(!hasCustomPrompt)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More prompt actions")
            .accessibilityLabel("More prompt actions")
        }
        .confirmationDialog(
            "Reset meeting notes prompt to the built-in default?",
            isPresented: $showResetPromptConfirmation,
            titleVisibility: .visible,
        ) {
            Button("Reset", role: .destructive) {
                try? FileManager.default.removeItem(at: AppPaths.customPromptFile)
                refreshCustomPromptState()
            }
        }
    }

    // MARK: - Helpers

    /// A typed key is handed to the connection being left before the change,
    /// and the key field then shows the selected connection's key.
    private func switchConnection(_ change: () -> Void) {
        apiKeyDrafts.commitPending(to: settings)
        change()
        apiKeyDrafts.reloadOpenAI(from: settings)
        availableModels = []
        connectionTestResult = nil
        testingConnection = false
    }

    private func refreshCustomPromptState() {
        hasCustomPrompt = FileManager.default.fileExists(atPath: AppPaths.customPromptFile.path)
    }

    func testConnection() {
        testingConnection = true
        didAttemptConnectionTest = true
        connectionTestResult = nil
        let connectionID = settings.activeOpenAIConnectionID
        Task {
            let apiKey = settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey
            let result = await OpenAIProtocolGenerator.testConnection(
                endpoint: settings.openAIEndpoint,
                model: settings.openAIModel,
                apiKey: apiKey,
                apiKeyPlacement: settings.openAIAPIKeyPlacement,
                apiKeyHeaderName: settings.openAIAPIKeyHeaderName,
            )
            // Another connection was selected meanwhile: its model must not be
            // replaced by this one's list.
            guard settings.activeOpenAIConnectionID == connectionID else { return }
            testingConnection = false
            switch result {
            case let .success(models):
                availableModels = models
                if !models.isEmpty {
                    if !models.contains(settings.openAIModel) {
                        settings.openAIModel = models[0]
                    }
                    connectionTestResult = .success("Connected (\(models.count) models)")
                } else {
                    connectionTestResult = .success("Connected")
                }

            case let .failure(error):
                availableModels = []
                connectionTestResult = .failure(error.localizedDescription)
            }
        }
    }

    private func ensurePromptDirectory() {
        try? FileManager.default.createDirectory(
            at: AppPaths.customPromptFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
    }

    private func openCustomPrompt() {
        let url = AppPaths.customPromptFile
        if !FileManager.default.fileExists(atPath: url.path) {
            ensurePromptDirectory()
            try? ProtocolGenerator.protocolPrompt.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func importCustomPrompt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md")].compactMap(\.self)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a prompt file to import"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        ensurePromptDirectory()
        do {
            try OutputSettingsLogic.importPrompt(from: source, to: AppPaths.customPromptFile)
        } catch {
            logger.error("prompt_import_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private var outputDirDisplay: String {
        OutputSettingsLogic.displayPath(
            for: settings.effectiveOutputDir,
            home: FileManager.default.homeDirectoryForCurrentUser,
        )
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for recordings, transcripts and meeting notes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setCustomOutputDir(url)
    }
}

// Outside the struct body, which is at its length limit.
private extension OutputSettingsView {
    var languagePickerOptions: [String] {
        OutputSettingsLogic.mergePickerOptions(available: AppSettings.protocolLanguages, selected: settings.protocolLanguage)
    }

    var modelPickerOptions: [String] {
        OutputSettingsLogic.mergePickerOptions(available: availableModels, selected: settings.openAIModel)
    }
}
