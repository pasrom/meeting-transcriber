import Foundation
import Observation

// MARK: - AppNotifying

/// Notification abstraction that keeps AppKit out of AppState.
///
/// Real implementation: `NotificationManager` (AppKit, used in menu bar app).
/// Test implementation: `RecordingNotifier` (records calls, no side effects).
protocol AppNotifying {
    func notify(title: String, body: String)
}

// MARK: - AppState

/// Observable ViewModel that owns all business state and derived UI properties.
///
/// Extracted from `MeetingTranscriberApp` so that:
/// - Badge/watching logic is testable without instantiating the `@main` App struct.
/// - `BadgeKind.compute(...)` can be called directly in tests.
@Observable
@MainActor
final class AppState {
    // MARK: - Dependencies

    let settings: AppSettings
    let whisperKit: WhisperKitEngine
    let parakeetEngine: ParakeetEngine
    private let notifier: any AppNotifying

    // MARK: - State

    var watchLoop: WatchLoop?
    var pipelineQueue: PipelineQueue
    var updateChecker: UpdateChecker

    // MARK: - Init

    init(
        settings: AppSettings = AppSettings(),
        whisperKit: WhisperKitEngine? = nil,
        parakeetEngine: ParakeetEngine? = nil,
        notifier: any AppNotifying = SilentNotifier(),
        updateChecker: UpdateChecker? = nil,
    ) {
        self.settings = settings
        self.whisperKit = whisperKit ?? WhisperKitEngine()
        self.parakeetEngine = parakeetEngine ?? ParakeetEngine()
        self.notifier = notifier
        self.updateChecker = updateChecker ?? UpdateChecker()
        self.pipelineQueue = PipelineQueue()
    }

    /// The active transcription engine based on the current settings.
    var activeTranscriptionEngine: any TranscribingEngine {
        settings.transcriptionEngine == .parakeet ? parakeetEngine : whisperKit
    }

    // MARK: - Derived properties

    var isWatching: Bool {
        watchLoop?.isActive == true && watchLoop?.isManualRecording == false
    }

    var currentBadge: BadgeKind {
        BadgeKind.compute(
            watchLoopActive: watchLoop?.isActive == true,
            watchLoopState: watchLoop?.state ?? .idle,
            transcriberState: watchLoop?.transcriberState ?? .idle,
            activeJobState: pipelineQueue.activeJobs.first?.state,
            updateAvailable: updateChecker.availableUpdate != nil,
        )
    }

    var currentStateLabel: String {
        if let loop = watchLoop, loop.isActive {
            return loop.transcriberState.label
        }
        return "Idle"
    }

    private static let isoFormatter = ISO8601DateFormatter()

    var currentStatus: TranscriberStatus? {
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

    // MARK: - Start / Stop

    func toggleWatching() {
        if let loop = watchLoop, loop.isManualRecording { return }
        if let loop = watchLoop, loop.isActive {
            loop.stop()
            watchLoop = nil
        } else {
            // swiftlint:disable:next closure_body_length
            Task { @MainActor in
                _ = await Permissions.ensureMicrophoneAccess()

                if settings.transcriptionEngine == .whisperKit {
                    whisperKit.language = settings.whisperLanguageOrNil
                }
                pipelineQueue = makePipelineQueue()

                let detector: MeetingDetecting = PowerAssertionDetector()

                let loop = WatchLoop(
                    detector: detector,
                    pipelineQueue: pipelineQueue,
                    pollInterval: settings.pollInterval,
                    endGracePeriod: settings.endGrace,
                    noMic: settings.noMic,
                    micDeviceUID: settings.micDeviceUID.isEmpty ? nil : settings.micDeviceUID,
                )

                loop.onStateChange = { [weak loop, notifier] _, newState in
                    switch newState {
                    case .recording:
                        if let meeting = loop?.currentMeeting {
                            notifier.notify(
                                title: "Meeting Detected",
                                body: "Recording: \(meeting.windowTitle)",
                            )
                        }

                    case .error:
                        if let err = loop?.lastError {
                            notifier.notify(title: "Error", body: err)
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

    func startManualRecording(pid: pid_t, appName: String, title: String) {
        // Stop auto-watch if active
        if let loop = watchLoop, loop.isActive, !loop.isManualRecording {
            loop.stop()
            watchLoop = nil
        }

        Task { @MainActor in
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
                notifier.notify(
                    title: "Manual Recording",
                    body: "Recording: \(title)",
                )
            } catch {
                notifier.notify(title: "Error", body: error.localizedDescription)
                watchLoop = nil
            }
        }
    }

    func stopManualRecording() {
        watchLoop?.stopManualRecording()
        watchLoop = nil
    }

    func enqueueFiles(_ urls: [URL]) {
        ensurePipelineQueue()

        for url in urls {
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

    // MARK: - Pipeline

    func ensurePipelineQueue() {
        guard pipelineQueue.engine == nil else { return }
        if settings.transcriptionEngine == .whisperKit {
            whisperKit.language = settings.whisperLanguageOrNil
        }
        pipelineQueue = makePipelineQueue()
        configurePipelineCallbacks()
    }

    func makePipelineQueue() -> PipelineQueue {
        let queue = PipelineQueue(
            engine: activeTranscriptionEngine,
            diarizationFactory: { FluidDiarizer() },
            protocolGeneratorFactory: { [self] in makeProtocolGenerator() },
            outputDir: settings.effectiveOutputDir,
            diarizeEnabled: settings.diarize,
            numSpeakers: settings.numSpeakers,
            micLabel: settings.micName,
        )
        queue.loadSnapshot()
        queue.recoverOrphanedRecordings()
        return queue
    }

    func makeProtocolGenerator() -> ProtocolGenerating {
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

    func configurePipelineCallbacks() {
        pipelineQueue.onJobStateChange = { [notifier] job, _, newState in
            switch newState {
            case .done:
                notifier.notify(title: "Protocol Ready", body: job.meetingTitle)

            case .error:
                if let err = job.error {
                    notifier.notify(title: "Error", body: err)
                }

            default:
                break
            }
        }
    }
}

// MARK: - SilentNotifier

/// No-op notifier for CLI targets and tests that don't need notifications.
struct SilentNotifier: AppNotifying {
    func notify(title _: String, body _: String) {}
}
