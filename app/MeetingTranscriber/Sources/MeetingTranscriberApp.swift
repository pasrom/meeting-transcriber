import Combine
import SwiftUI

extension Notification.Name {
    static let autoWatchStart = Notification.Name("autoWatchStart")
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
            NSLog("Auto-watch: scheduling start in 3s")
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
            .onReceive(NotificationCenter.default.publisher(for: .autoWatchStart)) { _ in
                if !isWatching {
                    NSLog("Auto-watch: starting via notification")
                    toggleWatching()
                }
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
        NSLog("toggleWatching called, isWatching=\(isWatching)")
        if let loop = watchLoop, loop.isActive {
            NSLog("Stopping watch loop")
            loop.stop()
            watchLoop = nil
        } else {
            Task {
                let micOK = await Permissions.ensureMicrophoneAccess()
                if !micOK {
                    NSLog("Warning: Microphone access denied — recording without mic")
                }
                let axOK = Permissions.ensureAccessibilityAccess()
                if !axOK {
                    NSLog("Warning: Accessibility access not granted — mute detection disabled")
                }

                var patterns: [AppMeetingPattern] = []
                if settings.watchTeams { patterns.append(.teams) }
                if settings.watchZoom { patterns.append(.zoom) }
                if settings.watchWebex { patterns.append(.webex) }
                if patterns.isEmpty { patterns = AppMeetingPattern.all }
                // Always include simulator for debug/testing
                if !patterns.contains(where: { $0.appName == "MeetingSimulator" }) {
                    patterns.append(.simulator)
                }

                NSLog("Creating WatchLoop with patterns: \(patterns.map(\.appName)), diarize=\(settings.diarize)")
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

                    loop.onStateChange = { [notifications] _, newState in
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

    // MARK: - Actions

    private func openLastProtocol() {
        if let path = watchLoop?.lastProtocolPath {
            NSWorkspace.shared.open(path)
        }
    }

    private func openProtocolsFolder() {
        let protocols = WatchLoop.defaultOutputDir
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
        NSApplication.shared.terminate(nil)
    }
}
