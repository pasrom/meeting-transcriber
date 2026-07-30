import AppKit
import SwiftUI
import UserNotifications

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    var updateChecker: UpdateChecker?

    /// Latest notification visibility from `PermissionsController`, or nil
    /// before the first check. Browser-meeting recording depends on it (the
    /// consent prompt is a notification), and nothing else in the app can say so
    /// without using the channel that is broken.
    var notificationVisibility: NotificationVisibility?

    /// Nil until the first permission check. The case, not just the message:
    /// how total the failure is decides the headline.
    private var browserConsentReadiness: BrowserConsentReadiness? {
        guard let notificationVisibility else { return nil }
        return BrowserConsentReadiness.evaluate(
            browserMeetingsEnabled: settings.watchBrowserMeetings,
            visibility: notificationVisibility,
        )
    }

    var body: some View {
        // swiftlint:disable:next closure_body_length
        Form {
            Section("Mode") {
                Toggle("Record-only mode", isOn: $settings.recordOnly)
                    .accessibilityIdentifier(A11yID.recordOnlyToggle)
                if settings.recordOnly {
                    recordOnlyBanner
                }
            }

            Section("Apps to Watch") {
                Toggle("Microsoft Teams", isOn: $settings.watchTeams)
                Toggle("Zoom", isOn: $settings.watchZoom)
                Toggle("Webex", isOn: $settings.watchWebex)
                Toggle("WeChat", isOn: $settings.watchWeChat)
                Toggle("Tencent Meeting", isOn: $settings.watchTencentMeeting)
                Toggle("FaceTime", isOn: $settings.watchFaceTime)
                Toggle("WhatsApp", isOn: $settings.watchWhatsApp)
                Toggle("Browser Web Meetings (Google Chrome)", isOn: $settings.watchBrowserMeetings)
                    .accessibilityIdentifier(A11yID.watchBrowserToggle)
                Text("Detects meetings in Chrome (Google Meet, Whereby, web Zoom/Teams). Asks before recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                browserConsentWarning
            }

            Section("Detection") {
                HStack {
                    Text("Poll Interval")
                    Spacer()
                    TextField("", value: $settings.pollInterval, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.pollInterval, in: 1 ... 30, step: 0.5)
                        .labelsHidden()
                    Text("seconds").foregroundStyle(.secondary)
                }

                HStack {
                    Text("Grace Period")
                    Spacer()
                    TextField("", value: $settings.endGrace, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.endGrace, in: 1 ... 120, step: 1)
                        .labelsHidden()
                    Text("seconds").foregroundStyle(.secondary)
                }
            }

            if let updateChecker {
                updatesSection(updateChecker: updateChecker)
            }
        }
        .formStyle(.grouped)
    }

    /// Warns when browser watching is on but the consent prompt cannot reach the
    /// user. Rendered here rather than as a notification for the obvious reason,
    /// and kept out of the menu-bar permission badge because this permission only
    /// matters for this one opt-in feature.
    @ViewBuilder private var browserConsentWarning: some View {
        if let readiness = browserConsentReadiness,
           let headline = readiness.headline,
           let warning = readiness.warning {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.callout.weight(.semibold))
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(A11yID.browserConsentWarning)
                    Button("Open Notification Settings") {
                        NSWorkspace.shared.open(Self.notificationSettingsURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Deep link to System Settings > Notifications. Verified to land on the
    /// Notifications pane rather than merely opening the app.
    private static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.notifications",
    )!

    private var recordOnlyBanner: some View {
        let display = OutputSettingsLogic.displayPath(
            for: settings.effectiveOutputDir.appendingPathComponent("recordings"),
            home: FileManager.default.homeDirectoryForCurrentUser,
        )
        return Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Record-only mode is active.")
                    .font(.callout.weight(.semibold))
                Text(
                    "Files land in `\(display)`. Each recording gets a `<timestamp>_meta.json` " +
                        "sidecar next to its WAVs. No transcription, diarization, or protocol " +
                        "generation runs on this device.",
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
        }
        .padding(8)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier(A11yID.recordOnlyBanner)
    }

    private func updatesSection(updateChecker: UpdateChecker) -> some View {
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
}
