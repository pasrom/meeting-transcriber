import Combine
import SwiftUI

extension Notification.Name {
    static let autoWatchStart = Notification.Name("autoWatchStart")
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
}

@main
struct MeetingTranscriberApp: App {
    @State private var settings = AppSettings()
    @State private var watchLoop: WatchLoop?
    @State private var pipelineQueue = PipelineQueue()
    @Environment(\.openWindow) private var openWindow
    private let notifications = NotificationManager.shared
    private let whisperKit = WhisperKitEngine()

    private var isWatching: Bool {
        watchLoop?.isActive == true
    }

    init() {
        notifications.setUp()
        DualSourceRecorder.killOrphanedAudiotap()
        // Auto-watch: schedule on main run loop after app finishes launching
        if CommandLine.arguments.contains("--auto-watch")
            || UserDefaults.standard.bool(forKey: "autoWatch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .autoWatchStart, object: nil)
            }
        }
    }

    /// Whether the app should auto-start watching.
    private var shouldAutoWatch: Bool {
        CommandLine.arguments.contains("--auto-watch") || settings.autoWatch
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                status: currentStatus,
                isWatching: isWatching,
                pipelineQueue: pipelineQueue,
                onStartStop: toggleWatching,
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
                onQuit: quit
            )
        } label: {
            Label(
                currentStateLabel,
                systemImage: currentStateIcon
            )
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
            SettingsView(settings: settings, whisperKitEngine: whisperKit)
        }
        .windowResizability(.contentSize)
    }

    // MARK: - Status

    private static let isoFormatter = ISO8601DateFormatter()

    private var currentStatus: TranscriberStatus? {
        guard let loop = watchLoop, loop.isActive else { return nil }

        let meeting: MeetingInfo? = loop.currentMeeting.map {
            MeetingInfo(
                app: $0.pattern.appName,
                title: $0.windowTitle,
                pid: Int($0.windowPID)
            )
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
            pid: Int(ProcessInfo.processInfo.processIdentifier)
        )
    }

    private var currentStateLabel: String {
        if let loop = watchLoop, loop.isActive {
            return loop.transcriberState.label
        }
        return "Idle"
    }

    private var currentStateIcon: String {
        if let loop = watchLoop, loop.isActive {
            if loop.state == .recording {
                return "record.circle.fill"
            }
            if !pipelineQueue.activeJobs.isEmpty {
                return "gearshape.2.fill"
            }
            return loop.transcriberState.icon
        }
        return "waveform.circle"
    }

    // MARK: - Start / Stop

    private func toggleWatching() {
        if let loop = watchLoop, loop.isActive {
            loop.stop()
            watchLoop = nil
        } else {
            Task {
                let _ = await Permissions.ensureMicrophoneAccess()
                let _ = Permissions.ensureAccessibilityAccess()

                var patterns: [AppMeetingPattern] = []
                if settings.watchTeams { patterns.append(.teams) }
                if settings.watchZoom { patterns.append(.zoom) }
                if settings.watchWebex { patterns.append(.webex) }
                if patterns.isEmpty { patterns = AppMeetingPattern.all }
                // Always include simulator for debug/testing
                if !patterns.contains(where: { $0.appName == "MeetingSimulator" }) {
                    patterns.append(.simulator)
                }

                await MainActor.run {
                    whisperKit.language = settings.whisperLanguageOrNil
                    pipelineQueue = makePipelineQueue()

                    let loop = WatchLoop(
                        detector: MeetingDetector(patterns: patterns),
                        pipelineQueue: pipelineQueue,
                        pollInterval: settings.pollInterval,
                        endGracePeriod: settings.endGrace,
                        noMic: settings.noMic
                    )

                    loop.onStateChange = { [weak loop, notifications] _, newState in
                        switch newState {
                        case .recording:
                            if let meeting = loop?.currentMeeting {
                                notifications.notify(
                                    title: "Meeting Detected",
                                    body: "Recording: \(meeting.windowTitle)"
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

    private func makePipelineQueue() -> PipelineQueue {
        let queue = PipelineQueue(
            whisperKit: whisperKit,
            diarizationFactory: { FluidDiarizer() },
            protocolGenerator: DefaultProtocolGenerator(),
            outputDir: WatchLoop.defaultOutputDir,
            diarizeEnabled: settings.diarize,
            numSpeakers: settings.numSpeakers,
            micLabel: settings.micName
        )
        queue.loadSnapshot()
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
        panel.title = "Select Audio Files"
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        // Ensure queue has processing dependencies
        if pipelineQueue.whisperKit == nil {
            whisperKit.language = settings.whisperLanguageOrNil
            pipelineQueue = makePipelineQueue()
            configurePipelineCallbacks()
        }

        for url in panel.urls {
            let title = url.deletingPathExtension().lastPathComponent
            let job = PipelineJob(
                meetingTitle: title,
                appName: "File",
                mixPath: url,
                appPath: nil,
                micPath: nil,
                micDelay: 0
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
