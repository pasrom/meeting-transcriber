import AppKit
import SwiftUI

/// Pure derivations used by `OutputSettingsView`. Extracted so the wrapping
/// logic can be unit-tested without instantiating a SwiftUI host.
enum OutputSettingsLogic {
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
    /// What the Meeting Notes Templates section shows, over the templates
    /// folder this view was handed.
    @State private var templatesModel: ProtocolTemplatesModel
    /// The API key fields type into these, not into the Keychain.
    @StateObject private var apiKeyDrafts: ProtocolAPIKeyDrafts

    /// `templateStore` is the templates folder; tests hand in a temp folder.
    init(
        settings: AppSettings,
        templateStore: ProtocolTemplateStore = .production,
        // swiftlint:disable:next unneeded_escaping
        apiKeyDrafts: @autoclosure @escaping () -> ProtocolAPIKeyDrafts? = nil,
    ) {
        self.settings = settings
        _templatesModel = State(initialValue: ProtocolTemplatesModel(store: templateStore, settings: settings))
        _apiKeyDrafts = StateObject(wrappedValue: apiKeyDrafts() ?? ProtocolAPIKeyDrafts(settings: settings))
    }

    var body: some View {
        // swiftlint:disable:next closure_body_length
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
            recordingRetentionSection

            Section("Meeting Notes") {
                Toggle("Include full transcript in meeting notes", isOn: $settings.includeFullTranscriptInProtocol)
                    .accessibilityIdentifier(A11yID.includeFullTranscriptToggle)
                Toggle("Save raw transcript separately", isOn: $settings.saveRawTranscriptSeparately)
                    .accessibilityIdentifier(A11yID.saveRawTranscriptToggle)
                HelpfulToggle(
                    title: "Use AI meeting title for filenames",
                    help: SettingsHelp.aiTitleForFilenames,
                    isOn: $settings.useAITitleForFilenames,
                )
                .accessibilityIdentifier(A11yID.useAITitleForFilenamesToggle)

                Picker("LLM Provider", selection: $settings.protocolProvider) {
                    ForEach(ProtocolProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }

                providerConfigView

                Picker("Notes Language", selection: $settings.protocolLanguage) {
                    ForEach(languagePickerOptions, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
            }
            .accessibilityIdentifier(A11yID.protocolSection)
            .recordOnlyDisabled(settings.recordOnly)

            ProtocolTemplatesSettingsView(model: templatesModel)
                .recordOnlyDisabled(settings.recordOnly)
        }
        .formStyle(.grouped)
        .onAppear {
            #if !APPSTORE
                claudeBinaries = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            #endif
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
                Text("Binary used to generate meeting notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("API Key")
                    Spacer()
                    DraftTextField("", value: apiKeyDrafts.savedClaude, draft: $apiKeyDrafts.claude, secure: true) { key in
                        apiKeyDrafts.commitClaude(key, to: settings)
                    }
                    .frame(width: 200)
                    .accessibilityIdentifier(A11yID.claudeAPIKeyField)
                }
                Text("Optional. Leave empty to use your \"claude login\" session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only set this if that session can't stay signed in. An explicit key here is billed separately from your subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
        #endif

        case .openAICompatible:
            openAIConfigView

        case .none:
            Text("No LLM summarization will be generated. Raw transcripts are retained if no meeting notes are saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var openAIConfigView: some View { // swiftlint:disable:this attributes
        VStack(alignment: .leading, spacing: 4) {
            Text("Endpoint")
            TextField("http://localhost:1234/v1", text: $settings.openAIEndpoint)
                .textFieldStyle(.roundedBorder)
            Text("Base URL (e.g. http://localhost:1234/v1) or full chat-completions URL — both work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !availableModels.isEmpty {
            Picker("Model", selection: $settings.openAIModel) {
                ForEach(modelPickerOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        } else {
            HStack {
                Text("Model")
                Spacer()
                TextField("", text: $settings.openAIModel)
                    .frame(width: 200)
                    .multilineTextAlignment(.trailing)
            }
        }

        SamplingOverrideRow(
            parameter: .temperature,
            value: $settings.openAITemperature,
            toggleID: A11yID.openAITemperatureToggle,
            valueID: A11yID.openAITemperatureValue,
        )
        SamplingOverrideRow(
            parameter: .topP,
            value: $settings.openAITopP,
            toggleID: A11yID.openAITopPToggle,
            valueID: A11yID.openAITopPValue,
        )
        Text("Passed to the server only when switched on. Off leaves the server's own default in place.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("Some servers reject both together, and reasoning models often reject any value.")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            Text("API Key")
            Spacer()
            DraftTextField("", value: apiKeyDrafts.savedOpenAI, draft: $apiKeyDrafts.openAI, secure: true) { key in
                apiKeyDrafts.commitOpenAI(key, to: settings)
            }
            .frame(width: 200)
            .accessibilityIdentifier(A11yID.openAIAPIKeyField)
        }
        Text("Leave empty if your local server doesn't require authentication")
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("API Key Authentication", selection: $settings.openAIAPIKeyPlacement) {
            ForEach(OpenAIAPIKeyPlacement.allCases, id: \.self) { placement in
                Text(placement.label).tag(placement)
            }
        }
        .accessibilityIdentifier(A11yID.openAIAPIKeyPlacementPicker)

        if settings.openAIAPIKeyPlacement == .customHeader {
            HStack {
                Text("Header Name")
                Spacer()
                TextField("", text: $settings.openAIAPIKeyHeaderName)
                    .frame(width: 200)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(A11yID.openAIAPIKeyHeaderNameField)
            }
            Text("Sends the API key unchanged in this HTTP header, e.g. api-key.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !OpenAIProtocolGenerator.isValidAPIKeyHeaderName(
                settings.openAIAPIKeyHeaderName.trimmingCharacters(in: .whitespacesAndNewlines),
            ) {
                Text("Enter a valid HTTP header name. Content-Type, Content-Length, Host and other connection-level headers are reserved.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(A11yID.openAIAPIKeyHeaderNameWarning)
            }
        }

        HStack {
            Button {
                testConnection()
            } label: {
                HStack(spacing: 4) {
                    if testingConnection {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(availableModels.isEmpty ? "Fetch Models" : "Refresh Models")
                }
            }
            .disabled(testingConnection)

            if let result = connectionTestResult {
                switch result {
                case let .success(msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)

                case let .failure(msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .onAppear {
            if availableModels.isEmpty && !didAttemptConnectionTest {
                testConnection()
            }
        }
    }

    // MARK: - Helpers

    func testConnection() {
        testingConnection = true
        didAttemptConnectionTest = true
        connectionTestResult = nil
        Task {
            let apiKey = settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey
            let result = await OpenAIProtocolGenerator.testConnection(
                endpoint: settings.openAIEndpoint,
                model: settings.openAIModel,
                apiKey: apiKey,
                apiKeyPlacement: settings.openAIAPIKeyPlacement,
                apiKeyHeaderName: settings.openAIAPIKeyHeaderName,
            )
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

    private var languagePickerOptions: [String] {
        OutputSettingsLogic.mergePickerOptions(available: AppSettings.protocolLanguages, selected: settings.protocolLanguage)
    }

    private var modelPickerOptions: [String] {
        OutputSettingsLogic.mergePickerOptions(available: availableModels, selected: settings.openAIModel)
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

/// One optional sampling override: a toggle that switches it on and, while it
/// is on, a field and stepper for the value. Switching it off clears the value,
/// so the parameter is left out of the request and the server default applies.
private struct SamplingOverrideRow: View {
    let parameter: OpenAISamplingParameter
    @Binding var value: Double?
    let toggleID: String
    let valueID: String

    var body: some View {
        Toggle("Override \(parameter.label)", isOn: isOverridden)
            .accessibilityIdentifier(toggleID)

        if value != nil {
            HStack {
                Text(parameter.label)
                Spacer()
                TextField(parameter.label, value: currentValue, format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper(parameter.label, value: currentValue, in: parameter.range, step: 0.05)
                    .labelsHidden()
            }
            // A container element, so the identifier names the row instead
            // of being copied onto the label, field and stepper inside it.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(valueID)
        }
    }

    private var isOverridden: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { value = $0 ? OpenAISamplingParameter.initialOverride : nil },
        )
    }

    private var currentValue: Binding<Double> {
        Binding(
            // The row only renders while overridden; the fallback just makes it total.
            get: { value ?? OpenAISamplingParameter.initialOverride },
            set: { value = $0 },
        )
    }
}
