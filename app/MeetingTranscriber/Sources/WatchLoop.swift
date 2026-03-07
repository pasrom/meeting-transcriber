import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber", category: "WatchLoop")

/// Native Swift watch loop that replaces the Python watcher.
///
/// Orchestrates: meeting detection → recording → transcription → protocol generation.
@Observable
class WatchLoop {
    enum State: String, Sendable {
        case idle
        case watching
        case recording
        case transcribing
        case diarizing
        case generatingProtocol
        case done
        case error
    }

    private(set) var state: State = .idle
    private(set) var currentMeeting: DetectedMeeting?
    private(set) var lastProtocolPath: URL?
    private(set) var lastError: String?
    private(set) var detail: String = ""

    // Dependencies
    let detector: MeetingDetector
    let whisperKit: WhisperKitEngine
    let recorderFactory: () -> RecordingProvider
    let diarizationFactory: () -> DiarizationProvider
    let protocolGenerator: ProtocolGenerating

    // Settings
    let pollInterval: TimeInterval
    let endGracePeriod: TimeInterval
    let maxDuration: TimeInterval
    let outputDir: URL
    let diarizeEnabled: Bool
    let micLabel: String
    let noMic: Bool
    let claudeBin: String

    private var watchTask: Task<Void, Never>?

    /// Hook called when state changes (for UI updates, notifications, etc.)
    var onStateChange: ((State, State) -> Void)?

    init(
        detector: MeetingDetector = MeetingDetector(patterns: AppMeetingPattern.all),
        whisperKit: WhisperKitEngine = WhisperKitEngine(),
        recorderFactory: @escaping () -> RecordingProvider = { DualSourceRecorder() },
        diarizationFactory: @escaping () -> DiarizationProvider = { DiarizationProcess() },
        protocolGenerator: ProtocolGenerating = DefaultProtocolGenerator(),
        pollInterval: TimeInterval = 3.0,
        endGracePeriod: TimeInterval = 15.0,
        maxDuration: TimeInterval = 14400,
        outputDir: URL = WatchLoop.defaultOutputDir,
        diarizeEnabled: Bool = false,
        micLabel: String = "Me",
        noMic: Bool = false,
        claudeBin: String = "claude"
    ) {
        self.detector = detector
        self.whisperKit = whisperKit
        self.recorderFactory = recorderFactory
        self.diarizationFactory = diarizationFactory
        self.protocolGenerator = protocolGenerator
        self.pollInterval = pollInterval
        self.endGracePeriod = endGracePeriod
        self.maxDuration = maxDuration
        self.outputDir = outputDir
        self.diarizeEnabled = diarizeEnabled
        self.micLabel = micLabel
        self.noMic = noMic
        self.claudeBin = claudeBin
    }

    static var defaultOutputDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingTranscriber/protocols")
    }

    var isActive: Bool { state != .idle }

    // MARK: - Start / Stop

    func start() {
        guard watchTask == nil else { return }

        transition(to: .watching)
        detail = "Polling for meetings..."
        logger.info("Watch mode started (poll: \(self.pollInterval)s, grace: \(self.endGracePeriod)s)")

        watchTask = Task { [weak self] in
            guard let self else { return }
            await self.watchLoop()
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        currentMeeting = nil
        transition(to: .idle)
        detail = ""
        logger.info("Watch mode stopped")
    }

    // MARK: - Watch Loop

    private func watchLoop() async {
        while !Task.isCancelled {
            if let meeting = detector.checkOnce() {
                do {
                    try await handleMeeting(meeting)
                } catch {
                    let msg = "Pipeline error: \(error)"
                    logger.error("\(msg)")
                    let logFile = Self.defaultOutputDir.deletingLastPathComponent().appendingPathComponent("error.log")
                    try? (msg + "\n").data(using: .utf8)?.write(to: logFile)
                    lastError = error.localizedDescription
                    transition(to: .error)
                    detail = "Pipeline error: \(error.localizedDescription)"
                }

                detector.reset(appName: meeting.pattern.appName)

                if !Task.isCancelled {
                    // Keep done/error state visible for 30 seconds
                    if state == .done || state == .error {
                        try? await Task.sleep(for: .seconds(30))
                    }
                    transition(to: .watching)
                    detail = "Polling for meetings..."
                }
            }

            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    // MARK: - Meeting Handling

    func handleMeeting(_ meeting: DetectedMeeting) async throws {
        currentMeeting = meeting
        let title = Self.cleanTitle(meeting.windowTitle)

        // --- Recording ---
        transition(to: .recording)
        detail = "Recording: \(title)"

        let recorder = recorderFactory()
        try recorder.start(
            appPID: meeting.windowPID,
            noMic: noMic,
            micDeviceUID: nil
        )

        // Read participants (Teams)
        if meeting.pattern.appName == "Microsoft Teams",
           let participants = ParticipantReader.readParticipants(pid: meeting.windowPID),
           !participants.isEmpty {
            logger.info("Detected \(participants.count) participants")
            ParticipantReader.writeParticipants(participants, meetingTitle: title)
        }

        // Wait for meeting to end
        try await waitForMeetingEnd(meeting)

        // Stop recording
        let recording = try recorder.stop()

        // --- Transcription ---
        transition(to: .transcribing)
        detail = "Transcribing: \(title)"

        // Resample to 16kHz for WhisperKit
        let recDir = DualSourceRecorder.recordingsDir

        let transcript: String
        if let appPath = recording.appPath, let micPath = recording.micPath {
            // Resample both tracks to 16kHz
            let app16k = recDir.appendingPathComponent("app_16k.wav")
            let appSamples = try AudioMixer.loadWAVAsFloat32(url: appPath)
            try AudioMixer.saveWAV(samples: AudioMixer.resample(appSamples, from: 48000, to: 16000), sampleRate: 16000, url: app16k)

            let mic16k = recDir.appendingPathComponent("mic_16k.wav")
            let micSamples = try AudioMixer.loadWAVAsFloat32(url: micPath)
            try AudioMixer.saveWAV(samples: AudioMixer.resample(micSamples, from: 48000, to: 16000), sampleRate: 16000, url: mic16k)

            transcript = try await whisperKit.transcribeDualSource(
                appAudio: app16k,
                micAudio: mic16k,
                micDelay: recording.micDelay,
                micLabel: micLabel
            )
        } else {
            let mix16k = recDir.appendingPathComponent("mix_16k.wav")
            let mixSamples = try AudioMixer.loadWAVAsFloat32(url: recording.mixPath)
            try AudioMixer.saveWAV(samples: AudioMixer.resample(mixSamples, from: 48000, to: 16000), sampleRate: 16000, url: mix16k)
            transcript = try await whisperKit.transcribe(audioPath: mix16k)
        }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Empty transcript"
            transition(to: .error)
            return
        }

        // --- Diarization (optional) ---
        var finalTranscript = transcript
        if diarizeEnabled {
            // Clean stale IPC files before diarization
            let ipcDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".meeting-transcriber")
            for name in ["speaker_request.json", "speaker_response.json",
                         "speaker_count_request.json", "speaker_count_response.json"] {
                try? FileManager.default.removeItem(at: ipcDir.appendingPathComponent(name))
            }

            let diarizeProcess = diarizationFactory()
            if diarizeProcess.isAvailable {
                transition(to: .diarizing)
                detail = "Diarizing: \(title)"

                // Use mix audio for diarization
                let mix16k = DualSourceRecorder.recordingsDir.appendingPathComponent("mix_16k.wav")
                let mixSamples = try AudioMixer.loadWAVAsFloat32(url: recording.mixPath)
                try AudioMixer.saveWAV(
                    samples: AudioMixer.resample(mixSamples, from: 48000, to: 16000),
                    sampleRate: 16000, url: mix16k
                )

                do {
                    let diarization = try await diarizeProcess.run(
                        audioPath: mix16k,
                        numSpeakers: nil,
                        meetingTitle: title
                    )

                    // Re-transcribe segments and assign speakers
                    let appSegments = recording.appPath != nil
                        ? try await whisperKit.transcribeSegments(
                            audioPath: recDir.appendingPathComponent("app_16k.wav"))
                        : try await whisperKit.transcribeSegments(
                            audioPath: mix16k)

                    let labeled = DiarizationProcess.assignSpeakers(
                        transcript: appSegments,
                        diarization: diarization
                    )
                    finalTranscript = labeled.map(\.formattedLine).joined(separator: "\n")
                    logger.info("Diarization complete: \(diarization.segments.count) segments")
                } catch {
                    logger.warning("Diarization failed, using undiarized transcript: \(error.localizedDescription)")
                    // Continue with original transcript
                }
            } else {
                logger.info("Diarization not available (python-diarize not in bundle)")
            }
        }

        // Clean up IPC files from diarize.py
        let ipcDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".meeting-transcriber")
        for name in ["speaker_request.json", "speaker_response.json",
                     "speaker_count_request.json", "speaker_count_response.json"] {
            try? FileManager.default.removeItem(at: ipcDir.appendingPathComponent(name))
        }

        // Save transcript
        let txtPath = try ProtocolGenerator.saveTranscript(finalTranscript, title: title, dir: outputDir)
        logger.info("Transcript saved: \(txtPath.lastPathComponent)")

        // --- Protocol Generation ---
        transition(to: .generatingProtocol)
        detail = "Generating protocol: \(title)"

        let diarized = finalTranscript.range(of: #"\[\w[\w\s]*\]"#, options: .regularExpression) != nil
        let protocolMD = try await protocolGenerator.generate(
            transcript: finalTranscript,
            title: title,
            diarized: diarized,
            claudeBin: claudeBin
        )

        let fullMD = protocolMD + "\n\n---\n\n## Full Transcript\n\n" + transcript
        let mdPath = try ProtocolGenerator.saveProtocol(fullMD, title: title, dir: outputDir)
        logger.info("Protocol saved: \(mdPath.lastPathComponent)")

        lastProtocolPath = mdPath
        transition(to: .done)
        detail = "Protocol ready: \(title)"
    }

    // MARK: - Meeting End Detection

    func waitForMeetingEnd(_ meeting: DetectedMeeting) async throws {
        var graceStart: Date?
        let startTime = Date()

        while !Task.isCancelled {
            // Enforce max duration
            if Date().timeIntervalSince(startTime) > maxDuration {
                logger.info("Max recording duration reached (\(Int(self.maxDuration))s)")
                return
            }

            let active = detector.isMeetingActive(meeting)

            if active {
                if graceStart != nil {
                    graceStart = nil
                }
            } else {
                if graceStart == nil {
                    graceStart = Date()
                } else if let start = graceStart, Date().timeIntervalSince(start) >= endGracePeriod {
                    return
                }
            }

            try await Task.sleep(for: .seconds(pollInterval))
        }
    }

    // MARK: - Helpers

    private func transition(to newState: State) {
        let old = state
        state = newState
        if old != newState {
            onStateChange?(old, newState)
        }
    }

    /// Strip app suffixes from meeting titles for cleaner display.
    static func cleanTitle(_ title: String) -> String {
        let suffixes = [" | Microsoft Teams", " - Zoom", " - Webex"]
        for suffix in suffixes {
            if title.hasSuffix(suffix) {
                return String(title.dropLast(suffix.count))
            }
        }
        return title
    }

    /// Map WatchLoop state to TranscriberState for compatibility with existing UI.
    var transcriberState: TranscriberState {
        switch state {
        case .idle: .idle
        case .watching: .watching
        case .recording: .recording
        case .transcribing: .transcribing
        case .diarizing: .transcribing
        case .generatingProtocol: .generatingProtocol
        case .done: .protocolReady
        case .error: .error
        }
    }
}
