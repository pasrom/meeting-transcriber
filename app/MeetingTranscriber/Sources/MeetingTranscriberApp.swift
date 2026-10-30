import Combine
import os.log
import SwiftUI

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "Launch")

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
    // `.default` (not `.common`) so the timer never fires inside the status-bar
    // menu's tracking loop — see MenuBarIcon.animationRunLoopMode for why.
    private let iconTimer = Timer.publish(
        every: 0.4, on: .main, in: MenuBarIcon.animationRunLoopMode,
    ).autoconnect()

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

/// Bridges a SwiftUI `Window` scene down to its hosting `NSWindow` so
/// window-level AppKit properties can be configured. macOS 14 (our deployment
/// target) has no scene-level `.windowLevel` / collection-behavior modifiers
/// (those are macOS 15+), so a zero-size representable placed in the content's
/// `.background` is the idiomatic way to reach the window. `configure` runs
/// once the view is attached and on subsequent updates; the window properties
/// it sets are sticky and idempotent.
private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        if let window = nsView.window { configure(window) }
    }
}

// Not @main — AppLauncher owns the entry point so a selftest launch can
// divert before this scene (and AppState with it) is ever constructed.
struct MeetingTranscriberApp: App {
    // Holds every quit open until the pending pipeline snapshot is on disk.
    // Handed `appState` in `init`, through `AppDelegate.install`. Never read:
    // declaring the adaptor is what makes SwiftUI install the delegate, and
    // the analyzer cannot see that use.
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate // swiftlint:disable:this unused_declaration
    @State private var appState: AppState
    @State private var captionsWindow: LiveCaptionsWindowController?
    // Keeps the progress updater alive for the app's lifetime; it is seeded in
    // `init` and observes menu tracking on its own, so nothing reads it back and
    // the analyzer cannot see that use.
    @State private var menuProgressUpdater: MenuStageProgressUpdater // swiftlint:disable:this unused_declaration
    @Environment(\.openWindow)
    private var openWindow

    init() {
        // Built first, as the property initialiser it replaces was. Handed to
        // the application delegate here because `init` runs before the run
        // loop, so every quit request finds it, however early it comes and
        // whether or not the menu-bar item is ever shown.
        let state = AppState(pipelineEnvironment: .production, notifier: NotificationManager.shared)
        #if !APPSTORE
            PersistentDiagnosticLog.cleanup()
            // Reap any `log stream` children orphaned by a previous crash/SIGKILL
            // (re-parented to launchd) so they can't accumulate across launches.
            // `reapOrphans` is nonisolated, so it runs off the main actor.
            // The reap is deliberately NOT ordered before the streamer start — an
            // orphan surviving a few extra ms is benign next to blocking launch,
            // and the new streamer is matched by parent pid so it's never reaped.
            Task(priority: .utility) { await PersistentDiagnosticLog.reapOrphans() }
            state.startPersistentLogStreamer()
        #endif
        _appState = State(initialValue: state)
        AppDelegate.install(state)
        let updater = MenuStageProgressUpdater()
        updater.observe { [weak state] in state?.pipelineQueue }
        _menuProgressUpdater = State(initialValue: updater)
        AppPaths.migrateIfNeeded()
        NotificationManager.shared.setUp()
        state.pipeline.restorePendingNotionExports()
        // The verdict was taken in `AppLauncher.main()`, before `AppState` was
        // built. It is reported here because this is the first point at which
        // the notification centre is set up (issue #703).
        Self.reportPreviousExit(AppLauncher.previousExit, to: NotificationManager.shared)
        // Temp-file cleanup moved into the queue-build recovery flow
        // (`PipelineController.recoverStagedRecordings`): a crashed
        // `_app_raw.tmp` must be
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

    // One scene per declaration, not one `body` holding the whole tree. The
    // analyze build passes `-warn-long-function-bodies=300` with warnings as
    // errors, so a getter that type-checks slowly is a build failure, and the
    // whole tree as a single expression shared one budget and crossed it on a
    // GitHub-hosted runner. Each declaration below is type-checked on its own
    // budget. Nothing leaves `body`'s evaluation: the properties are read from
    // the same closures at the same moment, so `@Observable` records the same
    // reads, and the scene order, window ids and modifiers are unchanged.
    var body: some Scene {
        MenuBarExtra {
            menuBarContent
        } label: {
            menuBarLabel
        }

        speakerNamingWindow
        settingsWindow
        recordAppWindow
    }

    // MARK: - Menu Bar

    private var menuBarContent: some View {
        MenuBarView(
            status: appState.currentStatus,
            isWatching: appState.isWatching,
            pipelineQueue: appState.pipelineQueue,
            updateChecker: appState.updateChecker,
            onStartStop: { appState.watching.toggleWatching() },
            onRecordApp: { bringWindowToFront(id: "record-app") },
            onRecordMicrophone: { appState.watching.startMicrophoneRecording() },
            noMic: appState.settings.noMic,
            manualRecordingPendingOrActive: appState.watching.isManualRecording,
            onStopManualRecording: appState.isManualRecording ? {
                appState.watching.stopManualRecording()
            } : nil,
            onOpenProtocol: openProtocol,
            onOpenProtocolsFolder: openProtocolsFolder,
            onOpenSettings: {
                bringWindowToFront(id: "settings")
            },
            onNameSpeakers: appState.hasPendingSpeakerNamingJobs ? {
                showNamingWindow()
            } : nil,
            onProcessFiles: processAudioFiles,
            onDismissJob: { id in appState.pipelineQueue.removeJob(id: id) },
            onQuit: quit,
            pendingConsentApp: appState.pendingConsentApp,
            onAnswerPendingConsent: appState.answerPendingConsent,
            notionExportEnabled: appState.settings.notionExportEnabled,
        )
    }

    private var menuBarLabel: some View {
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
                appState.watching.toggleWatching(userInitiated: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSpeakerNaming)) { _ in
            showNamingWindow()
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
            let controller = captionsWindow ?? LiveCaptionsWindowController(
                state: appState.liveCaptions, size: appState.settings.liveCaptionsSize,
            )
            captionsWindow = controller
            if visible {
                controller.show()
            } else {
                controller.hide()
            }
        }
        // Not `initial: true`: the controller is created with the current
        // preset above, and a hidden bar picks the preset up on `show()`.
        .onChange(of: appState.settings.liveCaptionsSize) { _, size in
            captionsWindow?.apply(size: size)
        }
    }

    // MARK: - Windows

    private var speakerNamingWindow: some Scene {
        Window("Name Speakers", id: "speaker-naming") {
            speakerNamingContent
                // Pin the naming window so it stays visible + on top while the
                // user works in other apps instead of vanishing on focus loss
                // (issue #504). Applied via the hosting NSWindow because macOS 14
                // has no scene-level window-level / collection-behavior modifier.
                .background(WindowAccessor { NamingWindowPolicy.apply(to: $0) })
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
    }

    private var settingsWindow: some Scene {
        Window("Settings", id: "settings") {
            SettingsView(
                settings: appState.settings,
                whisperKitEngine: appState.engines.whisperKit,
                parakeetEngine: appState.engines.parakeetEngine,
                updateChecker: appState.updateChecker,
                notificationVisibility: appState.permissions.notificationVisibility,
                // Share the pipeline's actor instance so both writers serialise on
                // the same `recognition_log.jsonl` file. Fallback only fires in the
                // test-only PipelineQueue init that intentionally leaves it nil.
                recognitionStatsLog: appState.pipeline.queue.recognitionStatsLog ?? RecognitionStatsLog(),
                // Same actor instance the pipeline writes to, so both writers
                // serialise on stage_timing.jsonl. Fallback fires only in the
                // test-only PipelineQueue init that leaves it nil.
                stageTimingLog: appState.pipeline.queue.stageTimingLog ?? StageTimingLog(),
                enrollmentDiarizerFactory: { FluidDiarizer(mode: appState.settings.diarizerMode) },
                namingDialogActive: appState.pipeline.queue.pendingSpeakerNaming != nil,
                pipelineBusy: appState.pipeline.queue.isProcessing,
                onSpeakerMutate: appState.pipeline.queue.refreshKnownSpeakerNames,
                // The pipeline's file and the app's notifier, so Known Voices
                // and enrollment edit the same DB and report through one channel.
                speakerMatcherFactory: SpeakerMatcher.factory(
                    dbPath: appState.pipeline.speakersDB, notifier: appState.notifier,
                ),
            )
        }
        .windowResizability(.contentSize)
    }

    private var recordAppWindow: some Scene {
        Window("Record App", id: "record-app") {
            AppPickerView(
                appsProvider: SystemRunningAppsProvider(),
                // The controller's wide predicate, not `appState.isManualRecording`.
                // That one is loop-only for the menu bar's Stop item and reads
                // false for the whole in-flight window. This window outlives the
                // menu item that opened it — it closes only on its own Start or
                // Cancel — so it has to stay truthful across both halves.
                startWouldBeRefused: appState.watching.isManualRecording,
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

    /// Open the naming window on a pinned job, from the menu and from
    /// `.showSpeakerNaming` alike.
    private func showNamingWindow() {
        appState.pinShownNamingJob()
        bringWindowToFront(id: "speaker-naming")
    }

    private var speakerNamingContent: some View {
        Group {
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
        // Whatever opened the window or changed what it shows (a restored
        // window, an RPC answer for the shown job), the selection follows.
        .onChange(
            of: appState.pipeline.queue.namingJobID(preferring: appState.selectedNamingJobID),
            initial: true,
        ) { _, _ in
            appState.pinShownNamingJob()
        }
    }

    @ViewBuilder private var speakerNamingPicker: some View {
        if appState.pipeline.queue.pendingSpeakerNamingJobs.count > 1 {
            Picker("Meeting", selection: Binding(
                get: {
                    appState.pipeline.queue.namingJobID(preferring: appState.selectedNamingJobID)
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
        SpeakerNamingView.answering(
            data: data,
            knownSpeakerNames: appState.pipeline.queue.knownSpeakerNames,
            currentDiarizerMode: appState.pipeline.queue.usedDiarizerMode(forJobID: data.jobID)
                ?? appState.settings.diarizerMode,
            pendingJobCount: appState.pipeline.queue.pendingSpeakerNamingJobs.count,
            onDismissRequest: { closeWindow(id: "speaker-naming") },
            notice: appState.pipeline.queue.lateRerunFailure(forJobID: data.jobID)?.message,
            // Labelled: `onDismissRequest` is a closure too, and SwiftFormat
            // and SwiftLint disagree on trailing syntax for the last of two.
            // swiftlint:disable:next trailing_closure
            onAnswer: { result in
                if let refusal = appState.pipeline.queue.completeSpeakerNaming(jobID: data.jobID, result: result) {
                    return refusal.message
                }
                // The next job awaiting naming, pinned; none left closes the
                // window.
                appState.selectedNamingJobID = nil
                appState.pinShownNamingJob()
                if appState.selectedNamingJobID == nil { closeWindow(id: "speaker-naming") }
                return nil
            },
        )
    }

    // MARK: - UI Actions

    private func processAudioFiles() {
        let panel = NSOpenPanel()
        panel.title = "Select Audio or Video Files"
        panel.allowedContentTypes = AudioImportTypes.pickerTypes(
            ffmpegAvailable: FFmpegHelper.isAvailable,
        )
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        let pairingDelegate = PairedImportPanelDelegate()
        panel.delegate = pairingDelegate
        panel.accessoryView = pairingDelegate.accessoryView
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        appState.pipeline.enqueueFiles(panel.urls)
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

    /// Only asks to terminate: stopping watching and finishing a recording
    /// happen in `AppDelegate`, which every quit path goes through, and this
    /// one alone used to do them.
    private func quit() {
        logger.info("Menu Quit requested")
        NSApplication.shared.terminate(nil)
    }

    private func openProtocol(_ target: JobOpenTarget) {
        logger.info("Menu protocol open requested")
        Task {
            let opened = await ProtocolOpener().open(target)
            logger.info("Menu protocol open accepted: \(opened)")
        }
    }

    // MARK: - Pure Helpers (testable without @main)

    /// Tell the user when the previous run ended without a quit (issue #703),
    /// the one outcome they cannot see for themselves: a menu bar app that is
    /// gone looks exactly like one that is idle. A clean quit is the normal
    /// launch and stays silent; so does a second instance, which is not a
    /// crash, though it is logged because two instances share one marker and
    /// only the later one is covered from here on.
    static func reportPreviousExit(_ exit: PreviousExit, to notifier: any AppNotifying, now: Date = Date()) {
        switch exit {
        case .clean:
            break

        case let .stillRunning(pid):
            logger.warning("another_instance_running pid=\(pid, privacy: .public)")

        case let .unclean(lastAlive):
            logger.warning("previous_run_ended_without_quit lastAlive=\(lastAlive.description, privacy: .public)")
            let notice = PreviousExitNotice(lastAlive: lastAlive, now: now)
            // `.standard` on purpose, decided rather than defaulted. This is
            // posted at launch, which after a reboot or a login-item start is
            // when nobody is looking, and a banner is gone in seconds; but
            // macOS keeps it in Notification Center until it is dismissed, and
            // that list is where the user finds it when they next look.
            // `.timeSensitive` is reserved for a failure the user can still act
            // on while it is happening (see `NotificationUrgency`), and this
            // one is over: the app is back by the time it is posted, and
            // nothing the user does now recovers the window. Breaking through
            // Focus for a report about the past would spend that entitlement
            // on the wrong notification. It is the only surface carrying the
            // information; a second one (a menu item, a `/state` field) is the
            // follow-up if this proves too easy to miss.
            notifier.notify(title: PreviousExitNotice.title, body: notice.body, urgency: .standard)
        }
    }

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
