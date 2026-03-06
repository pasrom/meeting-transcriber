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
        debugWrite("start() called, creating watchTask")
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

    private static let debugLog: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingTranscriber")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("watchloop.log")
    }()

    private func debugWrite(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.debugLog.path) {
                if let handle = try? FileHandle(forWritingTo: Self.debugLog) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.debugLog)
            }
        }
    }

    private func watchLoop() async {
        debugWrite("watchLoop started, state=\(state.rawValue), diarize=\(diarizeEnabled), patterns=\(detector.patternNames)")
        while !Task.isCancelled {
            if let meeting = detector.checkOnce() {
                debugWrite("Meeting detected: \(meeting.windowTitle) (PID \(meeting.windowPID))")
                do {
                    try await handleMeeting(meeting)
                } catch {
                    let msg = "Pipeline error: \(error)"
                    NSLog(msg)
                    logger.error("\(msg)")
                    // Write to file for debugging
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
        debugWrite("handleMeeting: \(title), PID=\(meeting.windowPID)")

        // --- Recording ---
        transition(to: .recording)
        detail = "Recording: \(title)"

        let recorder = recorderFactory()
        debugWrite("recorder.start(PID=\(meeting.windowPID), noMic=\(noMic))")
        try recorder.start(
            appPID: meeting.windowPID,
            noMic: noMic,
            micDeviceUID: nil
        )
        debugWrite("recorder started, waiting for meeting end...")

        // Read participants (Teams)
        if meeting.pattern.appName == "Microsoft Teams",
           let participants = ParticipantReader.readParticipants(pid: meeting.windowPID),
           !participants.isEmpty {
            logger.info("Detected \(participants.count) participants")
            ParticipantReader.writeParticipants(participants, meetingTitle: title)
        }

        // Wait for meeting to end
        try await waitForMeetingEnd(meeting)
        debugWrite("waitForMeetingEnd returned, stopping recorder...")

        // Stop recording
        let recording = try recorder.stop()
        debugWrite("recorder stopped. mix=\(recording.mixPath.lastPathComponent), app=\(recording.appPath?.lastPathComponent ?? "nil"), mic=\(recording.micPath?.lastPathComponent ?? "nil")")

        // --- Transcription ---
        debugWrite("Starting transcription...")
        NSLog("Starting transcription for: \(title)")
        NSLog("WhisperKit model state: \(whisperKit.modelState)")
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

        debugWrite("Transcription done (\(transcript.count) chars)")

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debugWrite("ERROR: Empty transcript")
            lastError = "Empty transcript"
            transition(to: .error)
            return
        }

        // --- Diarization (optional) ---
        var finalTranscript = transcript
        if diarizeEnabled {
            let diarizeProcess = diarizationFactory()
            debugWrite("Diarization: available=\(diarizeProcess.isAvailable)")
            if diarizeProcess.isAvailable {
                detail = "Diarizing: \(title)"
                debugWrite("Running diarization...")

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
        debugWrite("waitForMeetingEnd: starting poll loop")

        while !Task.isCancelled {
            // Enforce max duration
            if Date().timeIntervalSince(startTime) > maxDuration {
                logger.info("Max recording duration reached (\(Int(self.maxDuration))s)")
                return
            }

            let active = detector.isMeetingActive(meeting)

            if active {
                if graceStart != nil {
                    debugWrite("waitForMeetingEnd: window reappeared")
                    graceStart = nil
                }
            } else {
                if graceStart == nil {
                    debugWrite("waitForMeetingEnd: window GONE, grace=\(endGracePeriod)s")
                    graceStart = Date()
                } else if let start = graceStart, Date().timeIntervalSince(start) >= endGracePeriod {
                    debugWrite("waitForMeetingEnd: grace expired → stopping")
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
        case .generatingProtocol: .generatingProtocol
        case .done: .protocolReady
        case .error: .error
        }
    }
}
