import ApplicationServices
import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    @State private var audioDevices: [(id: String, name: String)] = []
    @State private var micPermission: AVAuthorizationStatus = .notDetermined
    @State private var screenRecordingOK = false
    @State private var accessibilityOK = false
    var whisperKitEngine: WhisperKitEngine

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
                case .unloaded:
                    Button("Load Model") {
                        whisperKitEngine.modelVariant = settings.whisperKitModel
                        Task { await whisperKitEngine.loadModel() }
                    }
                default:
                    EmptyView()
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

            Section("Permissions") {
                PermissionRow(
                    label: "Screen Recording",
                    detail: "Required for meeting detection (window titles)",
                    granted: screenRecordingOK
                )
                PermissionRow(
                    label: "Microphone",
                    detail: micPermission == .authorized ? "Granted"
                        : micPermission == .notDetermined ? "Will prompt on first recording"
                        : "Denied — grant in System Settings",
                    granted: micPermission == .authorized,
                    warning: micPermission == .notDetermined
                )
                PermissionRow(
                    label: "Accessibility",
                    detail: "Optional — enables mute detection",
                    granted: accessibilityOK,
                    optional: true
                )

                Button("Open Privacy & Security Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
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
        .frame(width: 420, height: settings.diarize ? 610 : (settings.noMic ? 490 : 590))
        .onAppear {
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

    private func refreshAudioDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        audioDevices = session.devices.map { (id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// A row showing permission status with a colored icon.
struct PermissionRow: View {
    let label: String
    let detail: String
    var granted: Bool
    var warning: Bool = false
    var optional: Bool = false

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
        }
    }
}
