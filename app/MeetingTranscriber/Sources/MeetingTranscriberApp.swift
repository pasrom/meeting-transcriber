import Combine
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let autoWatchStart = Notification.Name("autoWatchStart")
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
}

@main
struct MeetingTranscriberApp: App {
    @State private var appState = AppState(notifier: NotificationManager.shared)
    @State private var iconAnimationFrame = 0
    @Environment(\.openWindow)
    private var openWindow
    private let iconTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    init() {
        AppPaths.migrateIfNeeded()
        NotificationManager.shared.setUp()
        DualSourceRecorder.cleanupTempFiles()
        // Auto-watch: schedule on main run loop after app finishes launching
        if CommandLine.arguments.contains("--auto-watch")
            || UserDefaults.standard.bool(forKey: "autoWatch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .autoWatchStart, object: nil)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                status: appState.currentStatus,
                isWatching: appState.isWatching,
                pipelineQueue: appState.pipelineQueue,
                updateChecker: appState.updateChecker,
                onStartStop: appState.toggleWatching,
                onRecordApp: { bringWindowToFront(id: "record-app") },
                onStopManualRecording: appState.watchLoop?.isManualRecording == true ? {
                    appState.stopManualRecording()
                } : nil,
                onOpenLastProtocol: openLastProtocol,
                onOpenProtocol: { url in NSWorkspace.shared.open(url) },
                onOpenProtocolsFolder: openProtocolsFolder,
                onOpenSettings: {
                    bringWindowToFront(id: "settings")
                },
                onNameSpeakers: appState.pipelineQueue.pendingSpeakerNamingJobs.isEmpty ? nil : {
                    bringWindowToFront(id: "speaker-naming")
                },
                onProcessFiles: processAudioFiles,
                onDismissJob: { id in appState.pipelineQueue.removeJob(id: id) },
                onQuit: quit,
            )
        } label: { // swiftlint:disable:this closure_body_length
            Label {
                Text(appState.currentStateLabel)
            } icon: {
                Image(nsImage: MenuBarIcon.image(
                    badge: appState.currentBadge,
                    animationFrame: iconAnimationFrame,
                    permissionOverlay: appState.permissionHealth?.isHealthy == false,
                ))
            }
            .onReceive(iconTimer) { _ in
                // Always tick so currentBadge is re-read every 0.4s.
                // Non-animated badges ignore animationFrame (cached frame 0).
                iconAnimationFrame = (iconAnimationFrame + 1) % MenuBarIcon.frameCount
            }
            .onReceive(NotificationCenter.default.publisher(for: .autoWatchStart)) { _ in
                if !appState.isWatching {
                    appState.toggleWatching()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSpeakerNaming)) { _ in
                bringWindowToFront(id: "speaker-naming")
            }
            .task {
                switch appState.settings.transcriptionEngine {
                case .whisperKit:
                    appState.whisperKit.modelVariant = appState.settings.whisperKitModel
                    appState.whisperKit.language = appState.settings.whisperLanguageOrNil
                    await appState.whisperKit.loadModel()

                case .parakeet:
                    await appState.parakeetEngine.loadModel()

                case .qwen3:
                    if #available(macOS 15, *) {
                        appState.qwen3Engine.language = appState.settings.qwen3LanguageOrNil
                        await appState.qwen3Engine.loadModel()
                    }
                }
            }
            .task {
                appState.updateChecker.startPeriodicChecks(settings: appState.settings)
            }
            .task {
                await appState.checkPermissions()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Re-check permissions when the user returns to the app (e.g. from System
                // Settings after toggling a permission). Debounced so rapid Cmd-Tab cycles
                // don't repeatedly churn the mic HAL via the 500 ms probe.
                Task { @MainActor in
                    await appState.checkPermissions(minimumInterval: 3)
                }
            }
        }

        Window("Name Speakers", id: "speaker-naming") {
            if let data = appState.pipelineQueue.speakerNamingData(
                forJobID: appState.selectedNamingJobID
            ) {
                VStack(spacing: 0) {
                    // Show picker when multiple pending
                    if appState.pipelineQueue.pendingSpeakerNamingJobs.count > 1 {
                        Picker("Meeting", selection: Binding(
                            get: {
                                appState.selectedNamingJobID
                                    ?? appState.pipelineQueue.pendingSpeakerNamingJobs.first?.id
                            },
                            set: { appState.selectedNamingJobID = $0 }
                        )) {
                            ForEach(appState.pipelineQueue.pendingSpeakerNamingJobs) { job in
                                Text(job.meetingTitle).tag(Optional(job.id))
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }

                    SpeakerNamingView(data: data) { result in
                        appState.pipelineQueue.completeSpeakerNaming(
                            jobID: data.jobID,
                            result: result
                        )
                        if appState.pipelineQueue.pendingSpeakerNamingJobs.isEmpty {
                            closeWindow(id: "speaker-naming")
                        } else {
                            // Auto-advance to next pending meeting
                            appState.selectedNamingJobID =
                                appState.pipelineQueue.pendingSpeakerNamingJobs.first?.id
                        }
                    }
                }
            } else {
                Text("No speaker data available.")
                    .padding()
            }
        }
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(
                settings: appState.settings,
                whisperKitEngine: appState.whisperKit,
                parakeetEngine: appState.parakeetEngine,
                qwen3Engine: {
                    if #available(macOS 15, *) {
                        return appState.qwen3Engine
                    }
                    return nil
                }(),
                updateChecker: appState.updateChecker,
            )
        }
        .windowResizability(.contentSize)

        Window("Record App", id: "record-app") {
            AppPickerView(
                onStartRecording: { pid, appName, title in
                    appState.startManualRecording(pid: pid, appName: appName, title: title)
                    closeWindow(id: "record-app")
                },
                onCancel: { closeWindow(id: "record-app") },
            )
        }
        .windowResizability(.contentSize)
    }

    // MARK: - UI Actions

    private func processAudioFiles() {
        let panel = NSOpenPanel()
        panel.title = "Select Audio or Video Files"
        var types: [UTType] = [
            .wav, .mp3, .aiff, .mpeg4Audio,
            .mpeg4Movie, .quickTimeMovie,
        ] + [UTType("public.flac")].compactMap(\.self)
        if FFmpegHelper.isAvailable {
            types += FFmpegHelper.ffmpegOnlyTypes
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        appState.enqueueFiles(panel.urls)
    }

    private func openLastProtocol() {
        if let job = appState.pipelineQueue.completedJobs.last,
           let path = job.protocolPath ?? job.transcriptPath {
            NSWorkspace.shared.open(path)
        }
    }

    private func bringWindowToFront(id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
        // Ensure the window is brought to front even if already open
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == id {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func closeWindow(id: String) {
        for window in NSApp.windows where window.identifier?.rawValue == id {
            window.close()
        }
    }

    private func openProtocolsFolder() {
        let protocols = appState.settings.effectiveOutputDir
        let accessing = protocols.startAccessingSecurityScopedResource()
        defer { if accessing { protocols.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        NSWorkspace.shared.open(protocols)
    }

    private func quit() {
        appState.watchLoop?.stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Pure Helpers (testable without @main)

    /// Whether auto-watch should be enabled based on CLI flags or user settings.
    static func shouldAutoWatch(
        commandLineArgs: [String] = CommandLine.arguments,
        autoWatchSetting: Bool = UserDefaults.standard.bool(forKey: "autoWatch"),
    ) -> Bool {
        commandLineArgs.contains("--auto-watch") || autoWatchSetting
    }

    /// Returns the protocol path from the last completed job, if any.
    static func lastCompletedProtocolPath(completedJobs: [PipelineJob]) -> URL? {
        completedJobs.last?.protocolPath
    }
}
