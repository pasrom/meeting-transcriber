import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AudioCaptureSession")

/// Orchestrates app audio capture + optional mic recording.
/// Replaces the CLI entry point — call `start()` and `stop()` directly from the host app.
@available(macOS 14.2, *)
public class AudioCaptureSession {
    private let pids: [pid_t]
    private let sampleRate: Int
    private let channels: Int
    private let appOutputURL: URL
    private let micOutputURL: URL?
    private let micDeviceUID: String?
    private let debugLogging: Bool
    private let appLiveSink: LiveAudioSink?
    private let micLiveSink: LiveAudioSink?

    private var appCapture: AppAudioCapture?
    private var micCapture: MicCaptureHandler?
    private var appFileHandle: FileHandle?

    /// - Parameter pids: PIDs to capture audio from. For Electron/WebView2
    ///   apps (Teams 2.x, Slack, Discord) this should include the root PID
    ///   plus helper/renderer children; for native Cocoa apps a
    ///   single-element array is fine.
    /// - Parameter appLiveSink: Optional real-time buffer callback for the app
    ///   audio track (CATap output, interleaved Float32 at the tap's native
    ///   rate, typically 48 kHz). Called from the IOProc thread — non-blocking.
    /// - Parameter micLiveSink: Optional real-time buffer callback for the mic
    ///   track (mono Float32 at file rate, typically 16 kHz post-resample).
    ///   Called from the AVAudioEngine tap thread — non-blocking.
    public init(
        pids: [pid_t],
        appOutputURL: URL,
        sampleRate: Int = 48000,
        channels: Int = 2,
        micOutputURL: URL? = nil,
        micDeviceUID: String? = nil,
        debugLogging: Bool = false,
        appLiveSink: LiveAudioSink? = nil,
        micLiveSink: LiveAudioSink? = nil,
    ) {
        self.pids = pids
        self.sampleRate = sampleRate
        self.channels = channels
        self.appOutputURL = appOutputURL
        self.micOutputURL = micOutputURL
        self.micDeviceUID = micDeviceUID
        self.debugLogging = debugLogging
        self.appLiveSink = appLiveSink
        self.micLiveSink = micLiveSink
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
            pids: pids,
            outputFileDescriptor: handle.fileDescriptor,
            sampleRate: sampleRate,
            channels: channels,
            debugLogging: debugLogging,
            liveSink: appLiveSink,
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
            let mic = MicCaptureHandler(
                outputURL: micURL,
                debugLogging: debugLogging,
                liveSink: micLiveSink,
            )
            do {
                try mic.start(deviceUID: micDeviceUID)
                micCapture = mic
            } catch {
                logger.error("Failed to start mic capture: \(error). Continuing with app audio only.")
            }
        }

        logger.info("Capture session started (PIDs \(self.pids), rate: \(self.sampleRate), channels: \(self.channels))")
    }

    /// Instantaneous app-audio level in dBFS, decayed to -120 when no buffer has
    /// arrived in the last 0.5 s. Drives the menu-bar asymmetric-silence indicator.
    public var appLevelDBFS: Double {
        appCapture?.currentLevelDBFS ?? -120
    }

    /// Instantaneous mic level in dBFS, decayed to -120 when no buffer has arrived
    /// in the last 0.5 s. Drives the menu-bar asymmetric-silence indicator.
    public var micLevelDBFS: Double {
        micCapture?.currentLevelDBFS ?? -120
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
