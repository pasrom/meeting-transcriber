import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var hasCustomPrompt = FileManager.default.fileExists(atPath: AppPaths.customPromptFile.path)

    enum ConnectionTestResult {
        case success(String)
        case failure(String)
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
            .accessibilityIdentifier("outputFolderSection")

            Section("Protocol Generation") {
                Picker("LLM Provider", selection: $settings.protocolProvider) {
                    ForEach(ProtocolProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }

                providerConfigView

                Picker("Protocol Language", selection: $settings.protocolLanguage) {
                    ForEach(AppSettings.protocolLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }

                promptControls
            }
            .accessibilityIdentifier("protocolSection")
            .recordOnlyDisabled(settings.recordOnly)
        }
        .formStyle(.grouped)
        .onAppear {
            #if !APPSTORE
                claudeBinaries = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            #endif
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
                Text("Binary used for protocol generation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
        #endif

        case .openAICompatible:
            openAIConfigView

        case .none:
            Text("Only the raw transcript will be saved — no LLM summarization.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var openAIConfigView: some View { // swiftlint:disable:this attributes
        VStack(alignment: .leading, spacing: 4) {
            Text("Endpoint")
            TextField("", text: $settings.openAIEndpoint)
                .textFieldStyle(.roundedBorder)
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

        HStack {
            Text("API Key")
            Spacer()
            SecureField("", text: $settings.openAIAPIKey)
                .frame(width: 200)
        }
        Text("Leave empty if your local server doesn't require authentication")
            .font(.caption)
            .foregroundStyle(.secondary)

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

    private var promptControls: some View {
        // swiftlint:disable:next closure_body_length
        HStack {
            Button("Edit Prompt") {
                openCustomPrompt()
                refreshCustomPromptState()
            }

            Button("Import Prompt") {
                importCustomPrompt()
                refreshCustomPromptState()
            }

            Button("Reset to Default") {
                showResetPromptConfirmation = true
            }
            .disabled(!hasCustomPrompt)
            .confirmationDialog(
                "Reset protocol prompt to the built-in default?",
                isPresented: $showResetPromptConfirmation,
                titleVisibility: .visible,
            ) {
                Button("Reset", role: .destructive) {
                    try? FileManager.default.removeItem(at: AppPaths.customPromptFile)
                    refreshCustomPromptState()
                }
            }

            Spacer()

            if hasCustomPrompt {
                Label("Custom prompt active", systemImage: "doc.text.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
            } else {
                Label("Using default prompt", systemImage: "doc.text")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: - Helpers

    private func refreshCustomPromptState() {
        hasCustomPrompt = FileManager.default.fileExists(atPath: AppPaths.customPromptFile.path)
    }

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

    private var modelPickerOptions: [String] {
        var options = availableModels
        if !settings.openAIModel.isEmpty && !options.contains(settings.openAIModel) {
            options.insert(settings.openAIModel, at: 0)
        }
        return options
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
        let dest = AppPaths.customPromptFile
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try? FileManager.default.replaceItemAt(dest, withItemAt: source)
        } else {
            try? FileManager.default.copyItem(at: source, to: dest)
        }
    }

    private var outputDirDisplay: String {
        let url = settings.effectiveOutputDir
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for protocol output"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setCustomOutputDir(url)
    }
}
