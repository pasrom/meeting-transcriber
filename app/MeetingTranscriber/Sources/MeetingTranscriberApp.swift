import Combine
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let autoWatchStart = Notification.Name("autoWatchStart")
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
    static let showSettings = Notification.Name("showSettings")
    static let closeSettings = Notification.Name("closeSettings")
}

/// Renders the menu-bar icon and ticks the animation frame in its own
/// view body. Keeping the timer + frame @State scoped here means the
/// surrounding `MeetingTranscriberApp` scene body never re-evaluates on
/// each tick — only this view does. Without this isolation, animating
/// badges (recording, transcribing, …) would cascade re-renders through
/// every open Window.
private struct AnimatedMenuBarIcon: View {
    let badge: BadgeKind
    let permissionOverlay: Bool
    let recordOnlyOverlay: Bool
    let micSilentOverlay: Bool
    let appSilentOverlay: Bool

    @State private var animationFrame = 0
    private let iconTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        Image(nsImage: MenuBarIcon.image(
            badge: badge,
            animationFrame: animationFrame,
            permissionOverlay: permissionOverlay,
            recordOnlyOverlay: recordOnlyOverlay,
            micSilentOverlay: micSilentOverlay,
            appSilentOverlay: appSilentOverlay,
        ))
        .onReceive(iconTimer) { _ in
            let next = MenuBarIcon.nextFrame(animationFrame, badge: badge)
            if next != animationFrame {
                animationFrame = next
            }
        }
    }
}

@main
struct MeetingTranscriberApp: App {
    @State private var appState = AppState(notifier: NotificationManager.shared)
    @State private var captionsWindow: LiveCaptionsWindowController?
    @Environment(\.openWindow)
    private var openWindow

    init() {
        AppPaths.migrateIfNeeded()
        NotificationManager.shared.setUp()
        // Temp-file cleanup moved into the queue-build recovery flow
        // (`PipelineController.makeQueue`): a crashed `_app_raw.tmp` must be
        // re-mixed by `recoverCrashedRecordings` BEFORE it's cleaned up, so the
        // delete can no longer run first here (issue #379).
        let suppressAutoWatch = ProcessInfo.processInfo.environment["MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH"] == "1"
        // Auto-watch: schedule on main run loop after app finishes launching.
        // E2E drivers that force channel-health flags via env var also set
        // `MEETINGTRANSCRIBER_DEBUG_SUPPRESS_AUTOWATCH=1` so a +3 s
        // `toggleWatching` doesn't reset the forced flag through the
        // normal `channelHealth.stop()` path.
        if (CommandLine.arguments.contains("--auto-watch")
            || UserDefaults.standard.bool(forKey: "autoWatch"))
            && !suppressAutoWatch {
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
                onStartStop: { appState.watching.toggleWatching() },
                onRecordApp: { bringWindowToFront(id: "record-app") },
                onStopManualRecording: appState.isManualRecording ? {
                    appState.watching.stopManualRecording()
                } : nil,
                onOpenLastProtocol: openLastProtocol,
                onOpenProtocol: { url in NSWorkspace.shared.open(url) },
                onOpenProtocolsFolder: openProtocolsFolder,
                onOpenSettings: {
                    bringWindowToFront(id: "settings")
                },
                onNameSpeakers: appState.hasPendingSpeakerNamingJobs ? {
                    bringWindowToFront(id: "speaker-naming")
                } : nil,
                onProcessFiles: processAudioFiles,
                onDismissJob: { id in appState.pipelineQueue.removeJob(id: id) },
                onQuit: quit,
            )
        } label: { // swiftlint:disable:this closure_body_length
            Label {
                Text(appState.currentStateLabel)
            } icon: {
                AnimatedMenuBarIcon(
                    badge: appState.currentBadge,
                    permissionOverlay: appState.hasPermissionProblem,
                    recordOnlyOverlay: appState.settings.recordOnly,
                    // `recordingSilentActive` paints both halves; folded into the
                    // hoisted overlay props so MenuBarIcon only needs the two
                    // per-channel overlay inputs.
                    micSilentOverlay: appState.micSilentOverlay,
                    appSilentOverlay: appState.appSilentOverlay,
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .autoWatchStart)) { _ in
                if !appState.isWatching {
                    appState.watching.toggleWatching()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSpeakerNaming)) { _ in
                bringWindowToFront(id: "speaker-naming")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
                bringWindowToFront(id: "settings")
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeSettings)) { _ in
                closeWindow(id: "settings")
            }
            .task {
                await appState.engines.preloadActiveModel()
            }
            .task {
                appState.updateChecker.startPeriodicChecks(settings: appState.settings)
            }
            .task {
                await appState.permissions.check()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Re-check permissions when the user returns to the app (e.g. from System
                // Settings after toggling a permission). Debounced so rapid Cmd-Tab cycles
                // don't repeatedly churn the mic HAL via the 500 ms probe.
                Task { @MainActor in
                    await appState.permissions.check(minimumInterval: 3)
                }
            }
            .onChange(of: appState.shouldShowLiveCaptions, initial: true) { _, visible in
                let controller = captionsWindow ?? LiveCaptionsWindowController(state: appState.liveCaptions)
                captionsWindow = controller
                if visible {
                    controller.show()
                } else {
                    controller.hide()
                }
            }
        }

        Window("Name Speakers", id: "speaker-naming") {
            speakerNamingContent
                .onAppear {
                    // Close restored window if no naming data available (macOS state restoration)
                    if appState.pipeline.queue.pendingSpeakerNamingJobs.isEmpty {
                        closeWindow(id: "speaker-naming")
                    }
                }
                // Auto-close when the pending list drains. Covers RPC-driven
                // skip (`POST /action/skipNaming`), where the data layer
                // transitions but the UI callback never fires.
                .onChange(of: appState.pipeline.queue.pendingSpeakerNamingJobs.isEmpty) { _, isEmpty in
                    if isEmpty {
                        closeWindow(id: "speaker-naming")
                    }
                }
        }
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(
                settings: appState.settings,
                whisperKitEngine: appState.engines.whisperKit,
                parakeetEngine: appState.engines.parakeetEngine,
                qwen3Engine: {
                    if #available(macOS 15, *) {
                        return appState.engines.qwen3Engine
                    }
                    return nil
                }(),
                updateChecker: appState.updateChecker,
                // Share the pipeline's actor instance so both writers serialise on
                // the same `recognition_log.jsonl` file. Fallback only fires in the
                // test-only PipelineQueue init that intentionally leaves it nil.
                recognitionStatsLog: appState.pipeline.queue.recognitionStatsLog ?? RecognitionStatsLog(),
                enrollmentDiarizerFactory: { FluidDiarizer(mode: appState.settings.diarizerMode) },
                namingDialogActive: appState.pipeline.queue.pendingSpeakerNaming != nil,
                pipelineBusy: appState.pipeline.queue.isProcessing,
                onSpeakerMutate: appState.pipeline.queue.refreshKnownSpeakerNames,
            )
        }
        .windowResizability(.contentSize)

        Window("Record App", id: "record-app") {
            AppPickerView(
                onStartRecording: { pid, appName, title in
                    appState.watching.startManualRecording(pid: pid, appName: appName, title: title)
                    closeWindow(id: "record-app")
                },
                onCancel: { closeWindow(id: "record-app") },
            )
        }
        .windowResizability(.contentSize)
    }

    // MARK: - Speaker Naming Window

    @ViewBuilder private var speakerNamingContent: some View {
        if let data = appState.pipeline.queue.speakerNamingData(
            forJobID: appState.selectedNamingJobID,
        ) {
            VStack(spacing: 0) {
                speakerNamingPicker
                speakerNamingForm(data: data)
            }
        } else {
            Text("No speaker data available.")
                .padding()
        }
    }

    @ViewBuilder private var speakerNamingPicker: some View {
        if appState.pipeline.queue.pendingSpeakerNamingJobs.count > 1 {
            Picker("Meeting", selection: Binding(
                get: {
                    appState.selectedNamingJobID
                        ?? appState.pipeline.queue.pendingSpeakerNamingJobs.first?.id
                },
                set: { appState.selectedNamingJobID = $0 },
            )) {
                ForEach(appState.pipeline.queue.pendingSpeakerNamingJobs) { job in
                    Text(job.meetingTitle).tag(Optional(job.id))
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private func speakerNamingForm(
        data: PipelineQueue.SpeakerNamingData,
    ) -> some View {
        SpeakerNamingView(
            data: data,
            knownSpeakerNames: appState.pipeline.queue.knownSpeakerNames,
            currentDiarizerMode: appState.pipeline.queue.usedDiarizerMode(forJobID: data.jobID)
                ?? appState.settings.diarizerMode,
        ) { result in
            appState.pipeline.queue.completeSpeakerNaming(jobID: data.jobID, result: result)
            if appState.pipeline.queue.pendingSpeakerNamingJobs.isEmpty {
                closeWindow(id: "speaker-naming")
            } else {
                appState.selectedNamingJobID =
                    appState.pipeline.queue.pendingSpeakerNamingJobs.first?.id
            }
        }
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

        let pairingDelegate = PairedImportPanelDelegate()
        panel.delegate = pairingDelegate
        panel.accessoryView = pairingDelegate.accessoryView
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        appState.pipeline.enqueueFiles(panel.urls)
    }

    private func openLastProtocol() {
        if let job = appState.pipeline.queue.completedJobs.last,
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
        appState.watching.watchLoop?.stop()
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
