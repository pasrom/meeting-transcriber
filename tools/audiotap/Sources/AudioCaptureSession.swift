import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AudioCaptureSession")

/// Errors raised by `AudioCaptureSession` itself, before either track's
/// hardware is touched. Deliberately not `@available`-gated so a caller can
/// match on it without the OS check the session class carries.
public enum AudioCaptureSessionError: LocalizedError, Equatable {
    /// Neither an app-audio nor a mic output URL was supplied, so the session
    /// would run and record nothing.
    case noTracksRequested

    public var errorDescription: String? {
        switch self {
        case .noTracksRequested:
            "Capture session needs at least one of an app-audio or a microphone output"
        }
    }
}

/// Orchestrates app audio capture + optional mic recording.
/// Replaces the CLI entry point — call `start()` and `stop()` directly from the host app.
@available(macOS 14.2, *)
public class AudioCaptureSession {
    /// What this session records and how. Stored whole rather than unpacked
    /// into ten properties: unpacking is a list to keep in sync, and the option
    /// that gets left out of it is the one nobody notices.
    private let config: AudioCaptureConfiguration

    private var appCapture: AppAudioCapture?
    private var micCapture: MicCaptureHandler?

    /// Set when a channel's capture was abandoned (issue #588), either because a
    /// restart attempt never returned or because the retry budget ran out.
    /// Terminal for the session, so the user needs to be told something more
    /// useful than "this channel is quiet". In the first case a wedged attempt
    /// also keeps a thread and a good share of a core until the process
    /// restarts. Read from the polling path that already watches channel levels.
    public private(set) var appCaptureGaveUp = false
    public private(set) var micCaptureGaveUp = false
    private var appFileHandle: FileHandle?

    /// Each option is documented on `AudioCaptureConfiguration`.
    public init(_ configuration: AudioCaptureConfiguration) {
        config = configuration
    }

    /// Start capturing app audio, mic audio, or both — whichever output URLs
    /// were supplied. At least one is required.
    public func start() throws {
        guard config.appOutputURL != nil || config.micOutputURL != nil else {
            throw AudioCaptureSessionError.noTracksRequested
        }

        if let appOutputURL = config.appOutputURL {
            // Create app output file and get its file descriptor
            // Restrict permissions to owner-only (0600) — audio may contain sensitive meeting content
            FileManager.default.createFile(
                atPath: appOutputURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600],
            )
            let handle = try FileHandle(forWritingTo: appOutputURL)

            let capture = AppAudioCapture(
                pids: config.pids,
                outputFileDescriptor: handle.fileDescriptor,
                sampleRate: config.sampleRate,
                channels: config.channels,
                debugLogging: config.debugLogging,
                liveSink: config.appLiveSink,
            )
            do {
                try capture.start()
            } catch {
                try? handle.close()
                throw error
            }
            appFileHandle = handle
            capture.onGiveUp = { [weak self] in self?.appCaptureGaveUp = true }
            appCapture = capture
        }

        // Start mic capture if requested
        if let micURL = config.micOutputURL {
            let mic = MicCaptureHandler(
                outputURL: micURL,
                debugLogging: config.debugLogging,
                liveSink: config.micLiveSink,
                debugFault: config.micDebugFault,
            )
            do {
                try mic.start(deviceUID: config.micDeviceUID)
                mic.onGiveUp = { [weak self] in self?.micCaptureGaveUp = true }
                micCapture = mic
            } catch {
                // With an app track this is a degradation and the recording is
                // still worth keeping, which is why it has always been
                // swallowed. Without one the microphone IS the recording, so
                // the same swallow would hand back a session that captures
                // nothing while reporting success. Nothing to tear down on the
                // way out: reaching here with no app capture means none was
                // ever started, so no file handle was opened either.
                guard appCapture != nil else { throw error }
                logger.error("Failed to start mic capture: \(error.localizedDescription, privacy: .public). Continuing with app audio only.")
            }
        }

        logger.info("Capture session started (PIDs \(self.config.pids), rate: \(self.config.sampleRate), channels: \(self.config.channels))")
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

        // Gather the raw per-track readings and hand the delay/rate/channel
        // arithmetic to a pure, unit-tested builder. The app file is what
        // `AppAudioCapture` actually WROTE — 16 kHz mono after the in-IOProc
        // resample, not the device's raw capture format.
        let result = AudioCaptureResult.make(
            appOutputURL: config.appOutputURL,
            micOutputURL: config.micOutputURL,
            configured: (sampleRate: config.sampleRate, channels: config.channels),
            app: .init(
                firstFrameTicks: appCapture?.appFirstFrameTime ?? 0,
                sampleRate: appCapture?.outputSampleRate ?? 0,
                channels: appCapture?.outputChannels ?? 0,
            ),
            mic: .init(
                recorded: micCapture != nil,
                firstFrameTicks: micCapture?.firstFrameTime ?? 0,
            ),
        )

        try? appFileHandle?.close()
        appFileHandle = nil
        appCapture = nil
        micCapture = nil

        logger.info("Capture session stopped (rate: \(result.actualSampleRate), channels: \(result.actualChannels), micDelay: \(result.micDelay))")
        return result
    }
}
