import Combine
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let autoWatchStart = Notification.Name("autoWatchStart")
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
}

@main
struct MeetingTranscriberApp: App {
    @State private var settings = AppSettings()
    @State private var watchLoop: WatchLoop?
    @State private var pipelineQueue = PipelineQueue()
    @State private var iconAnimationFrame = 0
    @State private var updateChecker = UpdateChecker()
    @Environment(\.openWindow)
    private var openWindow
    private let notifications = NotificationManager.shared
    private let whisperKit = WhisperKitEngine()
    private let iconTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private var isWatching: Bool {
        watchLoop?.isActive == true
    }

    init() {
        AppPaths.migrateIfNeeded()
        notifications.setUp()
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
                status: currentStatus,
                isWatching: isWatching,
                pipelineQueue: pipelineQueue,
                updateChecker: updateChecker,
                onStartStop: toggleWatching,
                onRecordApp: { bringWindowToFront(id: "record-app") },
                onStopManualRecording: watchLoop?.isManualRecording == true ? {
                    watchLoop?.stopManualRecording()
                    watchLoop = nil
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
                onDismissJob: { id in pipelineQueue.removeJob(id: id) },
                onQuit: quit,
            )
        } label: {
            Label {
                Text(currentStateLabel)
            } icon: {
                Image(nsImage: MenuBarIcon.image(
                    badge: currentBadge,
                    animationFrame: currentBadge.isAnimated ? iconAnimationFrame : 0,
                ))
            }
            .onReceive(iconTimer) { _ in
                guard currentBadge.isAnimated else { return }
                iconAnimationFrame = (iconAnimationFrame + 1) % MenuBarIcon.frameCount
            }
            .onReceive(NotificationCenter.default.publisher(for: .autoWatchStart)) { _ in
                if !isWatching {
                    toggleWatching()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSpeakerNaming)) { _ in
                bringWindowToFront(id: "speaker-naming")
            }
            .task {
                whisperKit.modelVariant = settings.whisperKitModel
                whisperKit.language = settings.whisperLanguageOrNil
                await whisperKit.loadModel()
            }
            .task {
                updateChecker.startPeriodicChecks(settings: settings)
            }
        }

        Window("Name Speakers", id: "speaker-naming") {
            if let data = pipelineQueue.pendingSpeakerNaming {
                SpeakerNamingView(data: data) { result in
                    pipelineQueue.completeSpeakerNaming(result: result)
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
                settings: settings,
                whisperKitEngine: whisperKit,
                updateChecker: updateChecker,
            )
        }
        .windowResizability(.contentSize)

        Window("Record App", id: "record-app") {
            AppPickerView(
                onStartRecording: { pid, appName, title in
                    startManualRecording(pid: pid, appName: appName, title: title)
                    closeWindow(id: "record-app")
                },
                onCancel: { closeWindow(id: "record-app") },
            )
        }
        .windowResizability(.contentSize)
    }

    // MARK: - Status

    private static let isoFormatter = ISO8601DateFormatter()

    private var currentStatus: TranscriberStatus? {
        guard let loop = watchLoop, loop.isActive else { return nil }

        let meeting: MeetingInfo? = if let manual = loop.manualRecordingInfo {
            MeetingInfo(
                app: manual.appName,
                title: manual.title,
                pid: Int(manual.pid),
            )
        } else {
            loop.currentMeeting.map { meeting in
                MeetingInfo(
                    app: meeting.pattern.appName,
                    title: meeting.windowTitle,
                    pid: Int(meeting.windowPID),
                )
            }
        }

        return TranscriberStatus(
            version: 1,
            timestamp: Self.isoFormatter.string(from: Date()),
            state: loop.transcriberState,
            detail: loop.detail,
            meeting: meeting,
            protocolPath: nil,
            error: loop.lastError,
            audioPath: nil,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
        )
    }

    private var currentStateLabel: String {
        if let loop = watchLoop, loop.isActive {
            return loop.transcriberState.label
        }
        return "Idle"
    }

    private var currentBadge: BadgeKind {
        if let loop = watchLoop, loop.isActive {
            if loop.state == .recording { return .recording }
            if let activeJob = pipelineQueue.activeJobs.first {
                switch activeJob.state {
                case .transcribing: return .transcribing
                case .diarizing: return .diarizing
                default: return .processing
                }
            }
            switch loop.transcriberState {
            case .waitingForSpeakerCount, .waitingForSpeakerNames: return .userAction
            case .protocolReady: return .done
            case .error: return .error
            case .transcribing, .recordingDone: return .transcribing
            case .generatingProtocol: return .processing
            default: return .inactive
            }
        }
        if updateChecker.availableUpdate != nil { return .updateAvailable }
        return .inactive
    }

    // MARK: - Start / Stop

    private func startManualRecording(pid: pid_t, appName: String, title: String) {
        // Stop auto-watch if active
        if let loop = watchLoop, loop.isActive, !loop.isManualRecording {
            loop.stop()
            watchLoop = nil
        }

        Task {
            _ = await Permissions.ensureMicrophoneAccess()

            ensurePipelineQueue()

            let loop = WatchLoop(
                recorderFactory: { DualSourceRecorder() },
                pipelineQueue: pipelineQueue,
                pollInterval: settings.pollInterval,
                noMic: settings.noMic,
                micDeviceUID: settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID,
            )
            watchLoop = loop

            do {
                try loop.startManualRecording(pid: pid, appName: appName, title: title)
                notifications.notify(
                    title: "Manual Recording",
                    body: "Recording: \(title)",
                )
            } catch {
                notifications.notify(title: "Error", body: error.localizedDescription)
                watchLoop = nil
            }
        }
    }

    private func toggleWatching() {
        if let loop = watchLoop, loop.isManualRecording { return }
        if let loop = watchLoop, loop.isActive {
            loop.stop()
            watchLoop = nil
        } else {
            // swiftlint:disable:next closure_body_length
            Task {
                _ = await Permissions.ensureMicrophoneAccess()
                #if !APPSTORE
                    _ = Permissions.ensureAccessibilityAccess()
                #endif

                #if !APPSTORE
                    var patterns: [AppMeetingPattern] = []
                    if settings.watchTeams { patterns.append(.teams) }
                    if settings.watchZoom { patterns.append(.zoom) }
                    if settings.watchWebex { patterns.append(.webex) }
                    if patterns.isEmpty { patterns = AppMeetingPattern.all }
                    // Always include simulator for debug/testing
                    if !patterns.contains(where: { $0.appName == "MeetingSimulator" }) {
                        patterns.append(.simulator)
                    }
                #endif

                await MainActor.run {
                    whisperKit.language = settings.whisperLanguageOrNil
                    pipelineQueue = makePipelineQueue()

                    #if APPSTORE
                        let detector: MeetingDetecting = PowerAssertionDetector()
                    #else
                        let detector: MeetingDetecting = MeetingDetector(patterns: patterns)
                    #endif

                    let loop = WatchLoop(
                        detector: detector,
                        pipelineQueue: pipelineQueue,
                        pollInterval: settings.pollInterval,
                        endGracePeriod: settings.endGrace,
                        noMic: settings.noMic,
                        micDeviceUID: settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID,
                    )

                    loop.onStateChange = { [weak loop, notifications] _, newState in
                        switch newState {
                        case .recording:
                            if let meeting = loop?.currentMeeting {
                                notifications.notify(
                                    title: "Meeting Detected",
                                    body: "Recording: \(meeting.windowTitle)",
                                )
                            }

                        case .error:
                            if let err = loop?.lastError {
                                notifications.notify(title: "Error", body: err)
                            }

                        default:
                            break
                        }
                    }

                    configurePipelineCallbacks()

                    watchLoop = loop
                    loop.start()
                }
            }
        }
    }

    // MARK: - Pipeline

    private func ensurePipelineQueue() {
        guard pipelineQueue.whisperKit == nil else { return }
        whisperKit.language = settings.whisperLanguageOrNil
        pipelineQueue = makePipelineQueue()
        configurePipelineCallbacks()
    }

    private func makeProtocolGenerator() -> ProtocolGenerating {
        switch settings.protocolProvider {
        #if !APPSTORE
            case .claudeCLI:
                ClaudeCLIProtocolGenerator(claudeBin: settings.claudeBin)
        #endif

        case .openAICompatible:
            OpenAIProtocolGenerator(
                endpoint: URL(string: settings.openAIEndpoint)
                    // swiftlint:disable:next force_unwrapping
                    ?? URL(string: "http://localhost:11434/v1/chat/completions")!,
                model: settings.openAIModel,
                apiKey: settings.openAIAPIKey.isEmpty ? nil : settings.openAIAPIKey,
            )
        }
    }

    private func makePipelineQueue() -> PipelineQueue {
        let queue = PipelineQueue(
            whisperKit: whisperKit,
            diarizationFactory: { FluidDiarizer() },
            protocolGeneratorFactory: { [self] in makeProtocolGenerator() },
            outputDir: WatchLoop.defaultOutputDir,
            diarizeEnabled: settings.diarize,
            numSpeakers: settings.numSpeakers,
            micLabel: settings.micName,
        )
        queue.loadSnapshot()
        queue.recoverOrphanedRecordings()
        return queue
    }

    private func configurePipelineCallbacks() {
        pipelineQueue.onJobStateChange = { [notifications] job, _, newState in
            switch newState {
            case .done:
                notifications.notify(title: "Protocol Ready", body: job.meetingTitle)

            case .error:
                if let err = job.error {
                    notifications.notify(title: "Error", body: err)
                }

            default:
                break
            }
        }
    }

    // MARK: - Actions

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

        // Ensure queue has processing dependencies
        ensurePipelineQueue()

        for url in panel.urls {
            let title = url.deletingPathExtension().lastPathComponent
            let job = PipelineJob(
                meetingTitle: title,
                appName: "File",
                mixPath: url,
                appPath: nil,
                micPath: nil,
                micDelay: 0,
            )
            pipelineQueue.enqueue(job)
        }
    }

    private func openLastProtocol() {
        if let job = pipelineQueue.completedJobs.last,
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
        let protocols = WatchLoop.defaultOutputDir
        try? FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        NSWorkspace.shared.open(protocols)
    }

    private func quit() {
        watchLoop?.stop()
        NSApplication.shared.terminate(nil)
    }
}
