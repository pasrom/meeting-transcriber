import AppKit
import ApplicationServices
import AVFoundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "AdvancedSettingsView")

private enum PrivacyPane: String {
    case screenCapture = "Privacy_ScreenCapture"
    case microphone = "Privacy_Microphone"
    case accessibility = "Privacy_Accessibility"

    var url: String {
        "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"
    }
}

struct AdvancedSettingsView: View {
    @Bindable var settings: AppSettings

    @State private var micPermission: AVAuthorizationStatus = .notDetermined
    @State private var screenRecordingOK = false
    @State private var accessibilityOK = false
    @State private var lastExportFile: String?
    @State private var lastExportError: String?

    var body: some View {
        // swiftlint:disable:next closure_body_length
        Form {
            Section("Permissions") {
                PermissionRow(
                    label: "Screen Recording",
                    detail: Self.screenRecordingDetail,
                    granted: screenRecordingOK,
                    help: "System Settings → Privacy & Security → Screen Recording → enable Meeting Transcriber",
                    settingsURL: PrivacyPane.screenCapture.url,
                )
                PermissionRow(
                    label: "Microphone",
                    detail: micPermission == .authorized ? "Granted"
                        : micPermission == .notDetermined ? "Will prompt on first recording"
                        : "Denied — click to open Settings",
                    granted: micPermission == .authorized,
                    warning: micPermission == .notDetermined,
                    help: "System Settings → Privacy & Security → Microphone → enable Meeting Transcriber",
                    settingsURL: PrivacyPane.microphone.url,
                )
                PermissionRow(
                    label: "Accessibility",
                    detail: "Optional — enables mute detection and meeting naming",
                    granted: accessibilityOK,
                    optional: true,
                    help: "System Settings → Privacy & Security → Accessibility → enable Meeting Transcriber",
                    settingsURL: PrivacyPane.accessibility.url,
                )

                Button("Refresh") {
                    refreshPermissions()
                }
                .font(.caption)
            }

            // swiftlint:disable:next closure_body_length
            Section("Diagnostics") {
                Toggle("Verbose Diagnostic Logging", isOn: $settings.verboseDiagnostics)
                Text(
                    "Logs detailed diagnostics across recording, transcription,"
                        + " diarization, and protocol generation. Used to debug"
                        + " issues. Off by default — toggle on, reproduce the"
                        + " problem, then click \"Export Diagnostics…\" below to"
                        + " attach a redacted log file to a bug report.",
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("Export Diagnostics…") { exportDiagnostics() }
                if let file = lastExportFile {
                    Text("Exported to: \(file)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = lastExportError {
                    Text("Export failed: \(err)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                #if !APPSTORE
                    Button("Open Diagnostic Logs Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([PersistentDiagnosticLog.logDirectory])
                    }
                    Text(
                        "Persistent logs are kept for 30 days at"
                            + " ~/Library/Logs/MeetingTranscriber/. Useful when"
                            + " you need to attach logs from a session that"
                            + " happened earlier today (or yesterday).",
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Toggle("Debug RPC Server", isOn: $settings.debugRPCEnabled)
                    Text(
                        "Exposes pipeline state on 127.0.0.1:9876 for `mt-cli`."
                            + " Localhost-only, bearer-token auth. Off by default;"
                            + " enable only when you need shell-driven inspection.",
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                    .textSelection(.enabled)
                LabeledContent("Build Date", value: Self.buildDate)
                    .textSelection(.enabled)
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
        .onAppear { refreshPermissions() }
    }

    #if APPSTORE
        private static let screenRecordingDetail = "Required for app audio capture"
    #else
        private static let screenRecordingDetail = "Required for meeting detection and app audio capture"
    #endif

    private static let versionString: String = {
        let version = Bundle.main.appVersion
        let commit = Bundle.main.gitCommitHash
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

    private func exportDiagnostics() {
        let stamp = Int(Date().timeIntervalSince1970)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTranscriber-diagnostics-\(stamp).log")
        do {
            let info = DiagnosticExporter.HeaderInfo(
                appVersion: Bundle.main.appVersion,
                commit: Bundle.main.gitCommitHash,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                settings: [
                    "verboseDiagnostics": "\(settings.verboseDiagnostics)",
                    "diarize": "\(settings.diarize)",
                    "vadEnabled": "\(settings.vadEnabled)",
                    "transcriptionEngine": settings.transcriptionEngine.rawValue,
                    "protocolProvider": settings.protocolProvider.rawValue,
                    "recordOnly": "\(settings.recordOnly)",
                ],
            )
            let count = try DiagnosticExporter.export(to: outURL, info: info)
            lastExportFile = outURL.lastPathComponent
            lastExportError = nil
            NSWorkspace.shared.activateFileViewerSelecting([outURL])
            logger.info(
                "diagnostics_exported lines=\(count, privacy: .public) file=\(outURL.lastPathComponent, privacy: .public)",
            )
        } catch {
            lastExportFile = nil
            lastExportError = error.localizedDescription
            logger.error(
                "diagnostics_export_failed error=\(error.localizedDescription, privacy: .public)",
            )
        }
    }
}
