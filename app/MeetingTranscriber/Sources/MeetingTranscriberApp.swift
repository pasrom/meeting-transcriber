import Combine
import SwiftUI

extension Notification.Name {
    static let autoWatchStart = Notification.Name("autoWatchStart")
    static let showSpeakerCount = Notification.Name("showSpeakerCount")
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
}

@main
struct MeetingTranscriberApp: App {
    @State private var settings = AppSettings()
    @State private var speakerRequest: SpeakerRequest?
    @State private var speakerCountRequest: SpeakerCountRequest?
    @State private var watchLoop: WatchLoop?
    @Environment(\.openWindow) private var openWindow
    private let notifications = NotificationManager.shared
    private let ipc = IPCManager()
    private let ipcPoller = IPCPoller()
    private let whisperKit = WhisperKitEngine()

    private var isWatching: Bool {
        watchLoop?.isActive == true
    }

    init() {
        notifications.setUp()
        // Pre-load WhisperKit model on app launch
        let engine = whisperKit
        Task {
            engine.modelVariant = AppSettings().whisperKitModel
            await engine.loadModel()
        }
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
                onStartStop: toggleWatching,
                onOpenLastProtocol: openLastProtocol,
                onOpenProtocolsFolder: openProtocolsFolder,
                onOpenSettings: {
                    bringWindowToFront(id: "settings")
                },
                onNameSpeakers: {
                    loadSpeakerRequest()
                    bringWindowToFront(id: "speaker-naming")
                },
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
            .onReceive(NotificationCenter.default.publisher(for: .showSpeakerCount)) { _ in
                bringWindowToFront(id: "speaker-count")
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSpeakerNaming)) { _ in
                bringWindowToFront(id: "speaker-naming")
            }
        }

        Window("Name Speakers", id: "speaker-naming") {
            if let request = speakerRequest {
                SpeakerNamingView(request: request) { mapping in
                    writeSpeakerResponse(mapping)
                    speakerRequest = nil
                    closeWindow(id: "speaker-naming")
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
                    closeWindow(id: "speaker-count")
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

    // MARK: - Status

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
        if let loop = watchLoop, loop.isActive {
            return loop.transcriberState.label
        }
        return "Idle"
    }

    private var currentStateIcon: String {
        if let loop = watchLoop, loop.isActive {
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
                    let loop = WatchLoop(
                        detector: MeetingDetector(patterns: patterns),
                        whisperKit: whisperKit,
                        pollInterval: settings.pollInterval,
                        endGracePeriod: settings.endGrace,
                        outputDir: WatchLoop.defaultOutputDir,
                        diarizeEnabled: settings.diarize,
                        micLabel: settings.micName,
                        noMic: settings.noMic
                    )

                    // IPC polling for speaker dialogs during diarization
                    ipcPoller.onSpeakerCountRequest = { request in
                        DispatchQueue.main.async {
                            speakerCountRequest = request
                            NotificationCenter.default.post(name: .showSpeakerCount, object: nil)
                        }
                    }
                    ipcPoller.onSpeakerRequest = { request in
                        DispatchQueue.main.async {
                            speakerRequest = request
                            NotificationCenter.default.post(name: .showSpeakerNaming, object: nil)
                        }
                    }

                    loop.onStateChange = { [notifications, ipcPoller] _, newState in
                        switch newState {
                        case .recording:
                            if let meeting = loop.currentMeeting {
                                notifications.notify(
                                    title: "Meeting Detected",
                                    body: "Recording: \(meeting.windowTitle)"
                                )
                            }
                        case .diarizing:
                            ipcPoller.start()
                        case .done:
                            ipcPoller.stop()
                            ipcPoller.reset()
                            notifications.notify(
                                title: "Protocol Ready",
                                body: "Protocol is ready."
                            )
                        case .error:
                            ipcPoller.stop()
                            ipcPoller.reset()
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

    // MARK: - Actions

    private func openLastProtocol() {
        if let path = watchLoop?.lastProtocolPath {
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

    private func loadSpeakerRequest() {
        speakerRequest = ipc.loadSpeakerRequest()
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
        NSApplication.shared.terminate(nil)
    }
}
