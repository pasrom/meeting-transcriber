import SwiftUI

@main
struct MeetingTranscriberApp: App {
    @State private var monitor = StatusMonitor()
    @State private var settings = AppSettings()
    @State private var speakerRequest: SpeakerRequest?
    @State private var speakerCountRequest: SpeakerCountRequest?
    @State private var nativeTranscription = NativeTranscriptionManager()
    @Environment(\.openWindow) private var openWindow
    private let pythonProcess = PythonProcess()
    private let windowListWriter = WindowListWriter()
    private let notifications = NotificationManager.shared
    private let ipc = IPCManager()

    init() {
        // LSUIElement in Info.plist hides Dock icon.
        // Defer notification setup to after bundle is available.
        notifications.setUp()
        // Always monitor status file so the app reacts to external
        // transcriber processes (e.g. speaker naming requests).
        monitor.start()

        // Auto-restart Python process on unexpected termination
        NotificationCenter.default.addObserver(
            forName: PythonProcess.unexpectedTermination,
            object: nil,
            queue: .main
        ) { [pythonProcess, settings, windowListWriter] notification in
            let crashLoop = notification.userInfo?["crashLoop"] as? Bool ?? false
            if crashLoop {
                NSLog("Python process crash loop detected — not restarting")
                return
            }
            NSLog("Python process terminated unexpectedly — restarting in 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                windowListWriter.start(interval: Double(settings.pollInterval))
                pythonProcess.start(arguments: settings.buildArguments())
            }
        }
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
            NSLog("State change: \(oldValue?.rawValue ?? "nil") → \(newValue.rawValue)")
            notifications.handleTransition(from: oldValue, to: newValue, status: status)

            if newValue == .recordingDone,
               let audioPath = status.audioPath,
               let meetingTitle = status.meeting?.title
            {
                NSLog("Native transcription: recording done, starting WhisperKit transcription")
                Task {
                    await nativeTranscription.handleRecordingDone(
                        audioPath: audioPath,
                        meetingTitle: meetingTitle,
                        pythonProcess: pythonProcess
                    )
                }
            }

            if newValue == .waitingForSpeakerCount {
                loadSpeakerCountRequest()
                NSApp.activate()
                openWindow(id: "speaker-count")
            }

            if newValue == .waitingForSpeakerNames {
                NSLog("Speaker naming: loading request...")
                loadSpeakerRequest()
                NSLog("Speaker naming: request loaded = \(speakerRequest != nil)")
                NSApp.activate()
                openWindow(id: "speaker-naming")
                NSLog("Speaker naming: openWindow called")
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
            windowListWriter.stop()
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
                // Pre-load WhisperKit model if native transcription selected
                if settings.transcriptionEngine == .whisperKit {
                    await nativeTranscription.engine.loadModel()
                }
                await MainActor.run {
                    monitor.start()
                    windowListWriter.start(interval: Double(settings.pollInterval))
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
        let protocols: URL
        if pythonProcess.isBundled {
            protocols = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MeetingTranscriber/protocols")
        } else {
            protocols = URL(fileURLWithPath: pythonProcess.projectRoot)
                .appendingPathComponent("protocols")
        }

        // Create if needed, then open
        try? FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        NSWorkspace.shared.open(protocols)
    }

    private func loadSpeakerRequest() {
        if let request = ipc.loadSpeakerRequest() {
            NSLog("Speaker naming: loaded \(request.speakers.count) speakers for '\(request.meetingTitle)'")
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
        windowListWriter.stop()
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
