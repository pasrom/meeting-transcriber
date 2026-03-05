import ApplicationServices
import AVFoundation
import SwiftUI

/// Token status icon and color based on whether a HuggingFace token is set.
func tokenStatusInfo(hasToken: Bool) -> (icon: String, color: String) {
    hasToken
        ? ("checkmark.circle.fill", "green")
        : ("exclamationmark.triangle.fill", "orange")
}

/// Check if Screen Recording permission is granted.
/// If CGWindowListCopyWindowInfo returns window titles for other apps, the permission is granted.
func checkScreenRecordingPermission() -> Bool {
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    // If we can see window names from other apps, permission is granted
    let ownPID = ProcessInfo.processInfo.processIdentifier
    return windowList.contains { info in
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID else { return false }
        return info[kCGWindowName as String] as? String != nil
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings

    @State private var tokenInput = ""
    @State private var hasToken = false
    @State private var audioDevices: [(id: String, name: String)] = []
    @State private var micPermission: AVAuthorizationStatus = .notDetermined
    @State private var screenRecordingOK = false
    @State private var accessibilityOK = false
    @State private var whisperKitEngine = WhisperKitEngine()

    private let whisperModels = [
        "large-v3-turbo-q5_0",
        "large-v3-turbo",
        "large-v3",
        "medium",
        "small",
        "base",
        "tiny",
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
                    Stepper("", value: $settings.endGrace, in: 5...120, step: 5)
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
                Picker("Engine", selection: $settings.transcriptionEngine) {
                    ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                if settings.transcriptionEngine == .python {
                    Picker("Whisper Model", selection: $settings.whisperModel) {
                        ForEach(whisperModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                } else {
                    HStack {
                        Text("WhisperKit Model")
                        Spacer()
                        TextField("Model variant", text: $settings.whisperKitModel)
                            .frame(width: 200)
                            .multilineTextAlignment(.trailing)
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

                    // HuggingFace Token
                    HStack {
                        Image(systemName: tokenStatusInfo(hasToken: hasToken).icon)
                            .foregroundStyle(hasToken ? Color.green : Color.orange)
                        Text(hasToken ? "HuggingFace token set" : "HuggingFace token required")
                            .foregroundStyle(.secondary)
                    }

                    SecureField("hf_...", text: $tokenInput)

                    HStack {
                        Button("Save Token") {
                            settings.setHFToken(tokenInput)
                            tokenInput = ""
                            hasToken = settings.hasHFToken
                        }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button("Clear") {
                            settings.setHFToken("")
                            tokenInput = ""
                            hasToken = false
                        }
                        .disabled(!hasToken)

                        Spacer()

                        Link("Get token",
                             destination: URL(string: "https://huggingface.co/settings/tokens")!)
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
        }
        .formStyle(.grouped)
        .frame(width: 420, height: settings.diarize ? 710 : (settings.noMic ? 490 : 590))
        .onAppear {
            hasToken = settings.hasHFToken
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        screenRecordingOK = checkScreenRecordingPermission()
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
