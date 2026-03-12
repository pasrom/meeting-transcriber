import ApplicationServices
import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    @State private var audioDevices: [(id: String, name: String)] = []
    @State private var claudeBinaries: [String] = ["claude"]
    @State private var micPermission: AVAuthorizationStatus = .notDetermined
    @State private var screenRecordingOK = false
    @State private var accessibilityOK = false
    @State private var testingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var availableModels: [String] = []
    var whisperKitEngine: WhisperKitEngine

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
        Form {
            Section("Apps to Watch") {
                Toggle("Microsoft Teams", isOn: $settings.watchTeams)
                Toggle("Zoom", isOn: $settings.watchZoom)
                Toggle("Webex", isOn: $settings.watchWebex)
            }

            Section("Recording") {
                HStack {
                    Text("Poll Interval")
                    Spacer()
                    TextField("", value: $settings.pollInterval, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.pollInterval, in: 1...30, step: 0.5)
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
                    Stepper("", value: $settings.endGrace, in: 1...120, step: 1)
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
                        Stepper("", value: $settings.numSpeakers, in: 0...10)
                            .labelsHidden()
                    }
                }
            }

            Section("Protocol Generation") {
                Picker("Provider", selection: $settings.protocolProvider) {
                    ForEach(ProtocolProvider.allCases, id: \.self) { provider in
                        Text(provider.label).tag(provider)
                    }
                }

                switch settings.protocolProvider {
                case .claudeCLI:
                    Picker("Claude CLI", selection: $settings.claudeBin) {
                        ForEach(claudeBinaries, id: \.self) { bin in
                            Text(bin).tag(bin)
                        }
                    }
                    Text("Binary used for protocol generation")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                            case .success(let msg):
                                Label(msg, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            case .failure(let msg):
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
            }

            Section("Permissions") {
                PermissionRow(
                    label: "Screen Recording",
                    detail: "Required for meeting detection (window titles)",
                    granted: screenRecordingOK,
                    help: "System Settings → Privacy & Security → Screen Recording → enable Meeting Transcriber",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
                PermissionRow(
                    label: "Microphone",
                    detail: micPermission == .authorized ? "Granted"
                        : micPermission == .notDetermined ? "Will prompt on first recording"
                        : "Denied — click to open Settings",
                    granted: micPermission == .authorized,
                    warning: micPermission == .notDetermined,
                    help: "System Settings → Privacy & Security → Microphone → enable Meeting Transcriber",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
                PermissionRow(
                    label: "Accessibility",
                    detail: "Optional — enables mute detection",
                    granted: accessibilityOK,
                    optional: true,
                    help: "System Settings → Privacy & Security → Accessibility → enable Meeting Transcriber",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )

                Button("Refresh") {
                    refreshPermissions()
                }
                .font(.caption)
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            claudeBinaries = ProtocolGenerator.availableClaudeBinaries()
            refreshPermissions()
        }
    }

    private static let versionString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let commit = Bundle.main.infoDictionary?["GitCommitHash"] as? String ?? "dev"
        return "\(version) (\(commit))"
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

    private func testConnection() {
        testingConnection = true
        connectionTestResult = nil
        Task {
            let apiKey = settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey
            let result = await OpenAIProtocolGenerator.testConnection(
                endpoint: settings.openAIEndpoint,
                model: settings.openAIModel,
                apiKey: apiKey
            )
            testingConnection = false
            switch result {
            case .success(let models):
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
            case .failure(let error):
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

    private func refreshAudioDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        audioDevices = session.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// A row showing permission status with a colored icon, tooltip, and click-to-open Settings.
/// A row showing permission status with a colored icon, info popover, and click-to-open Settings.
struct PermissionRow: View {
    let label: String
    let detail: String
    var granted: Bool
    var warning: Bool = false
    var optional: Bool = false
    var help: String = ""
    var settingsURL: String = ""

    @State private var showingHelp = false

    private var icon: String {
        if granted { return "checkmark.circle.fill" }
        if warning || optional { return "exclamationmark.triangle.fill" }
        return "xmark.circle.fill"
    }

    private var iconColor: Color {
        if granted { return .green }
        if warning || optional { return .orange }
        return .red
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !help.isEmpty {
                Button {
                    showingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(help)
                            .font(.callout)
                        if !settingsURL.isEmpty {
                            Button("Open System Settings") {
                                if let url = URL(string: settingsURL) {
                                    NSWorkspace.shared.open(url)
                                }
                                showingHelp = false
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }
}
