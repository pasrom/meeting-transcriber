import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AudioCaptureSession")

/// Orchestrates app audio capture + optional mic recording.
/// Replaces the CLI entry point — call `start()` and `stop()` directly from the host app.
@available(macOS 14.2, *)
public class AudioCaptureSession {
    private let pid: pid_t
    private let sampleRate: Int
    private let channels: Int
    private let appOutputURL: URL
    private let micOutputURL: URL?
    private let micDeviceUID: String?
    private let debugLogging: Bool

    private var appCapture: AppAudioCapture?
    private var micCapture: MicCaptureHandler?
    private var appFileHandle: FileHandle?

    public init(
        pid: pid_t,
        appOutputURL: URL,
        sampleRate: Int = 48000,
        channels: Int = 2,
        micOutputURL: URL? = nil,
        micDeviceUID: String? = nil,
        debugLogging: Bool = false,
    ) {
        self.pid = pid
        self.sampleRate = sampleRate
        self.channels = channels
        self.appOutputURL = appOutputURL
        self.micOutputURL = micOutputURL
        self.micDeviceUID = micDeviceUID
        self.debugLogging = debugLogging
    }

    /// Start capturing app audio (and optionally mic audio).
    public func start() throws {
        // Create app output file and get its file descriptor
        // Restrict permissions to owner-only (0600) — audio may contain sensitive meeting content
        FileManager.default.createFile(
            atPath: appOutputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        )
        let handle = try FileHandle(forWritingTo: appOutputURL)

        let capture = AppAudioCapture(
            pid: pid,
            outputFileDescriptor: handle.fileDescriptor,
            sampleRate: sampleRate,
            channels: channels,
            debugLogging: debugLogging,
        )
        do {
            try capture.start()
        } catch {
            try? handle.close()
            throw error
        }
        appFileHandle = handle
        appCapture = capture

        // Start mic capture if requested
        if let micURL = micOutputURL {
            let mic = MicCaptureHandler(outputURL: micURL, debugLogging: debugLogging)
            do {
                try mic.start(deviceUID: micDeviceUID)
                micCapture = mic
            } catch {
                logger.error("Failed to start mic capture: \(error). Continuing with app audio only.")
            }
        }

        logger.info("Capture session started (PID \(self.pid), rate: \(self.sampleRate), channels: \(self.channels))")
    }

    /// Stop all capture and return the result.
    public func stop() -> AudioCaptureResult {
        appCapture?.stop()
        micCapture?.stop()

        // Compute mic delay
        var micDelay: TimeInterval = 0
        if let app = appCapture, let mic = micCapture {
            let appTime = app.appFirstFrameTime
            let micTime = mic.firstFrameTime
            if appTime > 0 && micTime > 0 {
                micDelay = machTicksToSeconds(micTime) - machTicksToSeconds(appTime)
            }
        }

        let actualRate = appCapture?.actualSampleRate ?? 0
        let actualChannels = appCapture?.actualChannels ?? 0

        // Close file handle
        try? appFileHandle?.close()
        appFileHandle = nil

        let result = AudioCaptureResult(
            appAudioFileURL: appOutputURL,
            micAudioFileURL: micCapture != nil ? micOutputURL : nil,
            actualSampleRate: actualRate > 0 ? actualRate : sampleRate,
            actualChannels: actualChannels > 0 ? actualChannels : channels,
            micDelay: micDelay,
        )

        appCapture = nil
        micCapture = nil

        logger.info("Capture session stopped (rate: \(result.actualSampleRate), channels: \(result.actualChannels), micDelay: \(result.micDelay))")
        return result
    }
}
