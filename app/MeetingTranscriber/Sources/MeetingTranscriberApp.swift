import SwiftUI

@main
struct MeetingTranscriberApp: App {
    @State private var monitor = StatusMonitor()
    @State private var settings = AppSettings()
    @State private var speakerRequest: SpeakerRequest?
    @State private var speakerCountRequest: SpeakerCountRequest?
    @Environment(\.openWindow) private var openWindow
    private let pythonProcess = PythonProcess()
    private let notifications = NotificationManager.shared

    init() {
        // LSUIElement in Info.plist hides Dock icon.
        // Defer notification setup to after bundle is available.
        notifications.setUp()
        // Always monitor status file so the app reacts to external
        // transcriber processes (e.g. speaker naming requests).
        monitor.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                status: monitor.status,
                isWatching: pythonProcess.isRunning,
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
                monitor.status?.state.label ?? "Idle",
                systemImage: monitor.status?.state.icon ?? "waveform.circle"
            )
        }
        .onChange(of: monitor.status?.state) { oldValue, newValue in
            guard let newValue, let status = monitor.status else { return }
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

    private func toggleWatching() {
        if pythonProcess.isRunning {
            pythonProcess.stop()
        } else {
            Task {
                let micOK = await PythonProcess.ensureMicrophoneAccess()
                if !micOK {
                    print("Warning: Microphone access denied — recording without mic")
                }
                let axOK = PythonProcess.ensureAccessibilityAccess()
                if !axOK {
                    print("Warning: Accessibility access not granted — mute detection disabled")
                }
                await MainActor.run {
                    monitor.start()
                    pythonProcess.start(arguments: settings.buildArguments())
                }
            }
        }
    }

    private func openLastProtocol() {
        guard let path = monitor.status?.protocolPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func openProtocolsFolder() {
        let protocols = URL(fileURLWithPath: pythonProcess.projectRoot)
            .appendingPathComponent("protocols")

        // Create if needed, then open
        try? FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        NSWorkspace.shared.open(protocols)
    }

    private func loadSpeakerRequest() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
            .appendingPathComponent("speaker_request.json")

        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(SpeakerRequest.self, from: data)
        else { return }

        speakerRequest = request
    }

    private func loadSpeakerCountRequest() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
            .appendingPathComponent("speaker_count_request.json")

        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(SpeakerCountRequest.self, from: data)
        else { return }

        speakerCountRequest = request
    }

    private func writeSpeakerCountResponse(_ count: Int) {
        let response = SpeakerCountResponse(version: 1, speakerCount: count)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
            .appendingPathComponent("speaker_count_response.json")

        guard let data = try? JSONEncoder().encode(response) else {
            NSLog("SpeakerCount: failed to encode response")
            return
        }

        do {
            // .atomic writes to a temp file and renames, replacing any existing file
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("SpeakerCount: failed to write response: \(error)")
        }
    }

    private func writeSpeakerResponse(_ mapping: [String: String]) {
        let response = SpeakerResponse(version: 1, speakers: mapping)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
            .appendingPathComponent("speaker_response.json")

        guard let data = try? JSONEncoder().encode(response) else { return }

        // Atomic write: tmp file + rename
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".speaker_response.tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            try FileManager.default.moveItem(at: tmpURL, to: url)
        } catch {
            // Fallback: direct write (moveItem fails if target exists on some FS)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func quit() {
        if pythonProcess.isRunning {
            pythonProcess.stop()
            // Give Python time to clean up (graceful SIGINT shutdown)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                NSApplication.shared.terminate(nil)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }
}
