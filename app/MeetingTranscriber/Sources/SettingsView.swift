import ApplicationServices
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// swiftlint:disable:next type_body_length
struct SettingsView: View {
    @Bindable var settings: AppSettings

    @State private var audioDevices: [(id: String, name: String)] = []
    #if !APPSTORE
        @State private var claudeBinaries: [String] = ["claude"]
    #endif
    @State private var micPermission: AVAuthorizationStatus = .notDetermined
    @State private var screenRecordingOK = false
    @State private var accessibilityOK = false
    @State private var testingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var availableModels: [String] = []
    @State private var showResetPromptConfirmation = false
    @State private var hasCustomPrompt = FileManager.default.fileExists(atPath: AppPaths.customPromptFile.path)
    var whisperKitEngine: WhisperKitEngine
    var updateChecker: UpdateChecker?

    enum ConnectionTestResult {
        case success(String)
        case failure(String)
    }

    private let whisperKitModels: [(variant: String, label: String)] = [
        ("openai_whisper-large-v3-v20240930_turbo", "Large V3 Turbo (recommended)"),
        ("openai_whisper-large-v3-v20240930", "Large V3"),
        ("openai_whisper-large-v2", "Large V2"),
        ("openai_whisper-small", "Small"),
        ("openai_whisper-base", "Base"),
        ("openai_whisper-tiny", "Tiny"),
    ]

    private let whisperLanguages: [(code: String, label: String)] = [
        ("", "Auto-detect"),
        ("de", "Deutsch"),
        ("en", "English"),
        ("fr", "Fran\u{00E7}ais"),
        ("es", "Espa\u{00F1}ol"),
        ("it", "Italiano"),
        ("nl", "Nederlands"),
        ("pt", "Portugu\u{00EA}s"),
        ("ja", "日本語"),
        ("zh", "中文"),
    ]

    var body: some View {
        // swiftlint:disable:next closure_body_length
        Form {
            Section("Apps to Watch") {
                Toggle("Microsoft Teams", isOn: $settings.watchTeams)
                Toggle("Zoom", isOn: $settings.watchZoom)
                Toggle("Webex", isOn: $settings.watchWebex)
            }

            // swiftlint:disable:next closure_body_length
            Section("Recording") {
                HStack {
                    Text("Poll Interval")
                    Spacer()
                    TextField("", value: $settings.pollInterval, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.pollInterval, in: 1 ... 30, step: 0.5)
                        .labelsHidden()
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Grace Period")
                    Spacer()
                    TextField("", value: $settings.endGrace, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.endGrace, in: 1 ... 120, step: 1)
                        .labelsHidden()
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }

                Toggle("No Microphone (app audio only)", isOn: $settings.noMic)

                if !settings.noMic {
                    Picker("Microphone", selection: $settings.micDeviceUID) {
                        Text("System Default").tag("")
                        ForEach(audioDevices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .onAppear { refreshAudioDevices() }

                    HStack {
                        Text("Mic Speaker Name")
                        Spacer()
                        TextField("Me", text: $settings.micName)
                            .frame(width: 120)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Your name for dual-source mode. Leave empty to diarize mic track (multi-person room).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // swiftlint:disable:next closure_body_length
            Section("Transcription") {
                Picker("Model", selection: $settings.whisperKitModel) {
                    ForEach(whisperKitModels, id: \.variant) { model in
                        Text(model.label).tag(model.variant)
                    }
                }

                Picker("Language", selection: $settings.whisperLanguage) {
                    ForEach(whisperLanguages, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }

                // Model status
                switch whisperKitEngine.modelState {
                case .downloading:
                    ProgressView(value: whisperKitEngine.downloadProgress)
                        .progressViewStyle(.linear)
                    Text("Downloading model... \(Int(whisperKitEngine.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .loading:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading model...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .loaded:
                    Label("Model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)

                case .unloaded, .unloading:
                    Button("Load Model") {
                        whisperKitEngine.modelVariant = settings.whisperKitModel
                        Task { await whisperKitEngine.loadModel() }
                    }

                case .prewarming, .prewarmed, .downloaded:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Preparing model...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Speaker Diarization", isOn: $settings.diarize)

                if settings.diarize {
                    HStack {
                        Text("Expected Speakers")
                        Spacer()
                        Text(settings.numSpeakers == 0 ? "Auto" : "\(settings.numSpeakers)")
                            .frame(width: 40)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $settings.numSpeakers, in: 0 ... 10)
                            .labelsHidden()
                    }
                }
            }

            // swiftlint:disable:next closure_body_length
            Section("Protocol Generation") {
                Picker("Provider", selection: $settings.protocolProvider) {
                    ForEach(ProtocolProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }

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
                        if availableModels.isEmpty {
                            testConnection()
                        }
                    }
                }

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

            Section("Permissions") {
                PermissionRow(
                    label: "Screen Recording",
                    detail: Self.screenRecordingDetail,
                    granted: screenRecordingOK,
                    help: "System Settings → Privacy & Security → Screen Recording → enable Meeting Transcriber",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                )
                PermissionRow(
                    label: "Microphone",
                    detail: micPermission == .authorized ? "Granted"
                        : micPermission == .notDetermined ? "Will prompt on first recording"
                        : "Denied — click to open Settings",
                    granted: micPermission == .authorized,
                    warning: micPermission == .notDetermined,
                    help: "System Settings → Privacy & Security → Microphone → enable Meeting Transcriber",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                )
                PermissionRow(
                    label: "Accessibility",
                    detail: "Optional — enables mute detection and meeting naming",
                    granted: accessibilityOK,
                    optional: true,
                    help: "System Settings → Privacy & Security → Accessibility → enable Meeting Transcriber",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                )

                Button("Refresh") {
                    refreshPermissions()
                }
                .font(.caption)
            }

            if let updateChecker {
                // swiftlint:disable:next closure_body_length
                Section("Updates") {
                    Toggle("Check for Updates", isOn: $settings.checkForUpdates)

                    if settings.checkForUpdates {
                        Toggle("Include Pre-Releases", isOn: $settings.includePreReleases)
                    }

                    HStack {
                        Button {
                            updateChecker.checkNow(
                                includePreReleases: settings.includePreReleases,
                            )
                        } label: {
                            HStack(spacing: 4) {
                                if updateChecker.isChecking {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("Check Now")
                            }
                        }
                        .disabled(updateChecker.isChecking)

                        if let error = updateChecker.lastError {
                            Label(error, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        } else if let update = updateChecker.availableUpdate {
                            Label(
                                "Update available: \(update.tagName)",
                                systemImage: "arrow.down.circle.fill",
                            )
                            .foregroundStyle(.blue)
                            .font(.caption)
                        } else if updateChecker.lastCheckDate != nil {
                            Label("Up to date", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }

                    if let update = updateChecker.availableUpdate {
                        Button {
                            NSWorkspace.shared.open(update.dmgURL ?? update.htmlURL)
                        } label: {
                            Label(
                                "Download \(update.tagName)",
                                systemImage: "arrow.down.to.line",
                            )
                        }
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Self.versionString)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("Build Date")
                    Spacer()
                    Text(Self.buildDate)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("ffmpeg") {
                    Label(
                        FFmpegHelper.isAvailable ? "Available" : "Not installed",
                        systemImage: FFmpegHelper.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill",
                    )
                    .foregroundStyle(FFmpegHelper.isAvailable ? .green : .secondary)
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            #if !APPSTORE
                claudeBinaries = ClaudeCLIProtocolGenerator.availableClaudeBinaries()
            #endif
            refreshPermissions()
        }
    }

    #if APPSTORE
        private static let screenRecordingDetail = "Required for app audio capture"
    #else
        private static let screenRecordingDetail = "Required for meeting detection and app audio capture"
    #endif

    private static let versionString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let commit = Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? "dev"
        #if APPSTORE
            let variant = "App Store"
        #else
            let variant = "Homebrew"
        #endif
        return "\(version) (\(commit)) · \(variant)"
    }()

    private static let buildDate: String = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return "unknown" }
        return fmt.string(from: date)
    }()

    private func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        screenRecordingOK = Permissions.checkScreenRecording()
        accessibilityOK = AXIsProcessTrusted()
    }

    func testConnection() {
        testingConnection = true
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
                    // Auto-select first model if current selection is not available
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

    /// Options for the model picker: fetched models + current setting if not in list.
    private var modelPickerOptions: [String] {
        var options = availableModels
        if !settings.openAIModel.isEmpty && !options.contains(settings.openAIModel) {
            options.insert(settings.openAIModel, at: 0)
        }
        return options
    }

    private func refreshCustomPromptState() {
        hasCustomPrompt = FileManager.default.fileExists(atPath: AppPaths.customPromptFile.path)
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

    private func refreshAudioDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified,
        )
        audioDevices = session.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }
}
