import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Bindable var settings: AppSettings
    var updateChecker: UpdateChecker?
    /// Where "Copy Command" writes; tests pass a private one so they never
    /// clobber the user's clipboard.
    var pasteboard: NSPasteboard = .general

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                    .textSelection(.enabled)
                LabeledContent("Identifier", value: Bundle.main.bundleID)
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
                Link("GitHub", destination: Self.githubURL)
            }

            if let updateChecker {
                updatesSection(updateChecker: updateChecker)
            }
        }
        .formStyle(.grouped)
    }

    // swiftlint:disable:next force_unwrapping
    private static let githubURL = URL(string: "https://github.com/\(GitHubReleaseProvider.owner)/\(GitHubReleaseProvider.repo)")!

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

            updateAction(updateChecker: updateChecker)
        }
    }

    /// A Homebrew install gets the brew command instead of the DMG, so the
    /// update keeps Homebrew's record in step with the installed app.
    @ViewBuilder
    private func updateAction(updateChecker: UpdateChecker) -> some View {
        if let update = updateChecker.availableUpdate {
            let route = updateChecker.installRoute(for: update)
            switch route {
            case let .homebrew(command):
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button {
                    route.perform(pasteboard: pasteboard)
                } label: {
                    Label("Copy Command", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier(A11yID.updateCopyBrewCommand)

            case .download:
                Button {
                    route.perform()
                } label: {
                    Label(
                        "Download \(update.tagName)",
                        systemImage: "arrow.down.to.line",
                    )
                }
                .accessibilityIdentifier(A11yID.updateDownload)
            }
        }
    }
}
