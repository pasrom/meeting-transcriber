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
                    logger.error("Pipeline error: \(error.localizedDescription)")
                    lastError = error.localizedDescription
                    transition(to: .error)
                    detail = "Pipeline error: \(error.localizedDescription)"
                }

                detector.reset()

                if !Task.isCancelled {
                    transition(to: .watching)
                    detail = "Polling for meetings..."
                }
            }

            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    // MARK: - Meeting Handling

    private func handleMeeting(_ meeting: DetectedMeeting) async throws {
        currentMeeting = meeting
        let title = Self.cleanTitle(meeting.windowTitle)
        logger.info("Meeting detected: \(meeting.windowTitle)")

        // --- Recording ---
        transition(to: .recording)
        detail = "Recording: \(title)"

        // TODO: Start DualSourceRecorder here
        // For now, we record via audiotap as a Process
        let recordingDir = FileManager.default.temporaryDirectory
        let mixPath = recordingDir.appendingPathComponent("mix_\(UUID().uuidString).wav")

        // Wait for meeting to end
        try await waitForMeetingEnd(meeting)

        // TODO: Stop recorder, get RecordingResult
        // For now, skip actual recording — will be wired in full integration

        logger.info("Meeting ended: \(title)")

        guard FileManager.default.fileExists(atPath: mixPath.path) else {
            logger.warning("No audio recorded, skipping pipeline")
            lastError = "No audio recorded"
            transition(to: .error)
            return
        }

        // --- Transcription ---
        transition(to: .transcribing)
        detail = "Transcribing: \(title)"

        let transcript: String
        // Resample to 16kHz for WhisperKit
        let resampled = recordingDir.appendingPathComponent("mix_16k.wav")
        let samples = try AudioMixer.loadWAVAsFloat32(url: mixPath)
        let downsampled = AudioMixer.resample(samples, from: 48000, to: 16000)
        try AudioMixer.saveWAV(samples: downsampled, sampleRate: 16000, url: resampled)

        transcript = try await whisperKit.transcribe(audioPath: resampled)

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("Empty transcript, skipping protocol generation")
            lastError = "Empty transcript"
            transition(to: .error)
            return
        }

        // Save transcript
        let txtPath = try ProtocolGenerator.saveTranscript(transcript, title: title, dir: outputDir)
        logger.info("Transcript saved: \(txtPath.lastPathComponent)")

        // --- Protocol Generation ---
        transition(to: .generatingProtocol)
        detail = "Generating protocol: \(title)"

        let diarized = transcript.range(of: #"\[\w[\w\s]*\]"#, options: .regularExpression) != nil
        let protocolMD = try await ProtocolGenerator.generate(
            transcript: transcript,
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
                    logger.debug("Meeting window reappeared, cancelling grace period")
                    graceStart = nil
                }
            } else {
                if graceStart == nil {
                    logger.info("Meeting window gone, grace period (\(self.endGracePeriod)s)...")
                    graceStart = Date()
                } else if let start = graceStart, Date().timeIntervalSince(start) >= endGracePeriod {
                    logger.info("Grace period expired")
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
