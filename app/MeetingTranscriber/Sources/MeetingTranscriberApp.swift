import SwiftUI

@main
struct MeetingTranscriberApp: App {
    @State private var monitor = StatusMonitor()
    @State private var settings = AppSettings()
    @State private var speakerRequest: SpeakerRequest?
    @State private var speakerCountRequest: SpeakerCountRequest?
    @State private var watchLoop: WatchLoop?
    @Environment(\.openWindow) private var openWindow
    private let pythonProcess = PythonProcess()
    private let notifications = NotificationManager.shared
    private let ipc = IPCManager()

    /// Whether the native Swift pipeline is active (vs Python).
    private var isNativeMode: Bool {
        settings.transcriptionEngine == .whisperKit
    }

    /// Whether any watching mode is active.
    private var isWatching: Bool {
        if isNativeMode {
            return watchLoop?.isActive == true
        }
        return pythonProcess.isRunning
    }

    init() {
        notifications.setUp()
        // Monitor status file for Python-mode state and speaker naming IPC
        monitor.start()

        // Auto-restart Python process on unexpected termination (Python mode only)
        NotificationCenter.default.addObserver(
            forName: PythonProcess.unexpectedTermination,
            object: nil,
            queue: .main
        ) { [pythonProcess, settings] notification in
            guard settings.transcriptionEngine == .python else { return }
            let crashLoop = notification.userInfo?["crashLoop"] as? Bool ?? false
            if crashLoop {
                NSLog("Python process crash loop detected — not restarting")
                return
            }
            NSLog("Python process terminated unexpectedly — restarting in 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                pythonProcess.start(arguments: settings.buildArguments())
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                status: nativeStatus ?? monitor.status,
                isWatching: isWatching,
                onStartStop: toggleWatching,
                onOpenLastProtocol: openLastProtocol,
                onOpenProtocolsFolder: openProtocolsFolder,
                onOpenSettings: {
                    NSApp.activate()
                    openWindow(id: "settings")
                },
                onNameSpeakers: {
                    loadSpeakerRequest()
                    NSApp.activate()
                    openWindow(id: "speaker-naming")
                },
                onQuit: quit
            )
        } label: {
            Label(
                currentStateLabel,
                systemImage: currentStateIcon
            )
        }
        .onChange(of: monitor.status?.state) { oldValue, newValue in
            // Python mode state changes
            guard !isNativeMode else { return }
            guard let newValue, let status = monitor.status else { return }
            NSLog("State change: \(oldValue?.rawValue ?? "nil") → \(newValue.rawValue)")
            notifications.handleTransition(from: oldValue, to: newValue, status: status)

            if newValue == .waitingForSpeakerCount {
                loadSpeakerCountRequest()
                NSApp.activate()
                openWindow(id: "speaker-count")
            }

            if newValue == .waitingForSpeakerNames {
                loadSpeakerRequest()
                NSApp.activate()
                openWindow(id: "speaker-naming")
            }
        }

        Window("Name Speakers", id: "speaker-naming") {
            if let request = speakerRequest {
                SpeakerNamingView(request: request) { mapping in
                    writeSpeakerResponse(mapping)
                    speakerRequest = nil
                }
            } else {
                Text("No speaker data available.")
                    .padding()
            }
        }
        .windowResizability(.contentSize)

        Window("Speaker Count", id: "speaker-count") {
            if let request = speakerCountRequest {
                SpeakerCountView(request: request) { count in
                    writeSpeakerCountResponse(count)
                    speakerCountRequest = nil
                }
            } else {
                Text("No speaker count request available.")
                    .padding()
            }
        }
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(settings: settings)
        }
        .windowResizability(.contentSize)
    }

    // MARK: - Native Mode Status Bridge

    /// Build a TranscriberStatus from WatchLoop state for the UI.
    private var nativeStatus: TranscriberStatus? {
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
            timestamp: ISO8601DateFormatter().string(from: Date()),
            state: loop.transcriberState,
            detail: loop.detail,
            meeting: meeting,
            protocolPath: loop.lastProtocolPath?.path,
            error: loop.lastError,
            audioPath: nil,
            pid: Int(ProcessInfo.processInfo.processIdentifier)
        )
    }

    private var currentStateLabel: String {
        if isNativeMode, let loop = watchLoop, loop.isActive {
            return loop.transcriberState.label
        }
        return monitor.status?.state.label ?? "Idle"
    }

    private var currentStateIcon: String {
        if isNativeMode, let loop = watchLoop, loop.isActive {
            return loop.transcriberState.icon
        }
        return monitor.status?.state.icon ?? "waveform.circle"
    }

    // MARK: - Start / Stop

    private func toggleWatching() {
        if isNativeMode {
            toggleNativeWatching()
        } else {
            togglePythonWatching()
        }
    }

    private func toggleNativeWatching() {
        if let loop = watchLoop, loop.isActive {
            loop.stop()
            watchLoop = nil
        } else {
            Task {
                let micOK = await PythonProcess.ensureMicrophoneAccess()
                if !micOK {
                    NSLog("Warning: Microphone access denied — recording without mic")
                }
                let axOK = PythonProcess.ensureAccessibilityAccess()
                if !axOK {
                    NSLog("Warning: Accessibility access not granted — mute detection disabled")
                }

                // Build patterns from settings
                var patterns: [AppMeetingPattern] = []
                if settings.watchTeams { patterns.append(.teams) }
                if settings.watchZoom { patterns.append(.zoom) }
                if settings.watchWebex { patterns.append(.webex) }
                if patterns.isEmpty { patterns = AppMeetingPattern.all }

                let engine = WhisperKitEngine()
                engine.modelVariant = settings.whisperKitModel
                await engine.loadModel()

                await MainActor.run {
                    let loop = WatchLoop(
                        detector: MeetingDetector(patterns: patterns),
                        whisperKit: engine,
                        pollInterval: settings.pollInterval,
                        endGracePeriod: settings.endGrace,
                        outputDir: WatchLoop.defaultOutputDir,
                        diarizeEnabled: settings.diarize,
                        micLabel: settings.micName,
                        noMic: settings.noMic
                    )

                    loop.onStateChange = { [notifications] _, newState in
                        // Send notifications for key state changes
                        let label = WatchLoop.State.idle  // just to map
                        _ = label  // suppress warning
                        switch newState {
                        case .recording:
                            if let meeting = loop.currentMeeting {
                                notifications.notify(
                                    title: "Meeting Detected",
                                    body: "Recording: \(meeting.windowTitle)"
                                )
                            }
                        case .done:
                            notifications.notify(
                                title: "Protocol Ready",
                                body: "Protocol is ready."
                            )
                        case .error:
                            if let err = loop.lastError {
                                notifications.notify(title: "Error", body: err)
                            }
                        default:
                            break
                        }
                    }

                    watchLoop = loop
                    loop.start()
                }
            }
        }
    }

    private func togglePythonWatching() {
        if pythonProcess.isRunning {
            pythonProcess.stop()
        } else {
            Task {
                let micOK = await PythonProcess.ensureMicrophoneAccess()
                if !micOK {
                    NSLog("Warning: Microphone access denied — recording without mic")
                }
                let axOK = PythonProcess.ensureAccessibilityAccess()
                if !axOK {
                    NSLog("Warning: Accessibility access not granted — mute detection disabled")
                }
                await MainActor.run {
                    monitor.start()
                    pythonProcess.start(arguments: settings.buildArguments())
                }
            }
        }
    }

    // MARK: - Actions

    private func openLastProtocol() {
        if isNativeMode, let path = watchLoop?.lastProtocolPath {
            NSWorkspace.shared.open(path)
        } else if let path = monitor.status?.protocolPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func openProtocolsFolder() {
        let protocols: URL
        if isNativeMode || pythonProcess.isBundled {
            protocols = WatchLoop.defaultOutputDir
        } else {
            protocols = URL(fileURLWithPath: pythonProcess.projectRoot)
                .appendingPathComponent("protocols")
        }
        try? FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        NSWorkspace.shared.open(protocols)
    }

    private func loadSpeakerRequest() {
        if let request = ipc.loadSpeakerRequest() {
            NSLog("Speaker naming: loaded \(request.speakers.count) speakers")
            speakerRequest = request
        } else {
            NSLog("Speaker naming: file not found or unreadable")
        }
    }

    private func loadSpeakerCountRequest() {
        speakerCountRequest = ipc.loadSpeakerCountRequest()
    }

    private func writeSpeakerCountResponse(_ count: Int) {
        do {
            try ipc.writeSpeakerCountResponse(count)
        } catch {
            NSLog("SpeakerCount: failed to write response: \(error)")
        }
    }

    private func writeSpeakerResponse(_ mapping: [String: String]) {
        do {
            try ipc.writeSpeakerResponse(mapping)
        } catch {
            NSLog("Speaker naming: failed to write response: \(error)")
        }
    }

    private func quit() {
        watchLoop?.stop()
        if pythonProcess.isRunning {
            pythonProcess.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                NSApplication.shared.terminate(nil)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }
}
