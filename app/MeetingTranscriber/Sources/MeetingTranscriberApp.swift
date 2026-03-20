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
                onNameSpeakers: {
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
                }
            }
            .task {
                appState.updateChecker.startPeriodicChecks(settings: appState.settings)
            }
        }

        Window("Name Speakers", id: "speaker-naming") {
            if let data = appState.pipelineQueue.pendingSpeakerNaming {
                SpeakerNamingView(data: data) { result in
                    appState.pipelineQueue.completeSpeakerNaming(result: result)
                    closeWindow(id: "speaker-naming")
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
           let path = job.protocolPath {
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
}
