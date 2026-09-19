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

    /// The two handlers' hardware seams, nil in production. See the internal init.
    private let appAttemptBody: (() throws -> AppTapSession?)?
    private let micSessionFactory: (() -> any MicEngineSessionProviding)?

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

    /// Whether the microphone's output path was free when this start reached it.
    /// The handler creates that file itself, so anything already there belongs
    /// to the caller and a failed start must not delete it.
    private var micFileWasAbsentBeforeStart = false

    /// Each option is documented on `AudioCaptureConfiguration`.
    public convenience init(_ configuration: AudioCaptureConfiguration) {
        self.init(configuration, appAttemptBody: nil, micSessionFactory: nil)
    }

    /// Test seam forwarding `AppAudioCapture.attemptBody` and
    /// `MicCaptureHandler.sessionFactory`; the reasoning is on each of those.
    /// Not `public` because neither of them is.
    init(
        _ configuration: AudioCaptureConfiguration,
        appAttemptBody: (() throws -> AppTapSession?)?,
        micSessionFactory: (() -> any MicEngineSessionProviding)?,
    ) {
        config = configuration
        self.appAttemptBody = appAttemptBody
        self.micSessionFactory = micSessionFactory
    }

    /// Start capturing app audio, mic audio, or both — whichever output URLs
    /// were supplied. At least one is required.
    ///
    /// The microphone goes first, and that order is load-bearing (issue #693).
    /// Opening the input flips a Bluetooth headset out of A2DP into the call
    /// profile, which changes its sample rate. With the tap opened first, that
    /// rate change landed underneath an aggregate device that had been created
    /// and started but had not yet run its first IO cycle, and the tap then
    /// delivered nothing at all for the rest of the recording. Measured with a
    /// throwaway probe that is not in this repository: 9 failures in 30 starts
    /// with the tap first, 0 in 30 with the microphone first, which bounds what
    /// is left rather than proving it gone. An aggregate that has already run a
    /// cycle survives the same change with a fraction of a second of loss, which
    /// is why moving the flip ahead of the tap is the repair.
    ///
    /// Stated to the evidence, which is narrower than the story but points at
    /// the same repair. The diagnostics log attached to issue #693 holds eight
    /// recordings from one machine, seven of them reporting the rate their
    /// aggregate was created at:
    ///
    /// - Five were created at 24 kHz with the microphone side already reading
    ///   24 kHz, and every one delivered its first callback 37 to 50 ms later.
    /// - Two were created at 48 kHz while the microphone side already read
    ///   24 kHz. Neither ever delivered a buffer: no `Audio format:` line at
    ///   all, and `lastBufferAge=never` at stop.
    ///
    /// So the failures are not "a rate change arrived late". They are the
    /// aggregate being built against a device that was mid-transition, its
    /// output side still reporting A2DP while its input side had already moved
    /// to the call profile. That is why opening the microphone first is the
    /// repair: it drives the transition before the aggregate is created rather
    /// than underneath it.
    ///
    /// What this does NOT establish. Those five healthy runs were already fully
    /// in the call profile before the recording began, so they show which
    /// configuration survives, not that this order produces it. One machine,
    /// one session. And the survivor with a measured flip (the 2026-09-11
    /// excerpt) transitioned while its aggregate was already cycling, losing
    /// 0.32 s: that recording's `Mic: engine configuration changed` lands 194 ms
    /// after `Mic recording started`, which is the same event as the 836 ms
    /// measured from its first callback, not a second data point.
    ///
    /// The residual this leaves. A healthy first callback is 30 to 60 ms, but
    /// the slowest on record is 0.78 s (`NoFirstBufferProbeSchedule`), so a
    /// transition that begins after the aggregate is created can still land
    /// before its first cycle. The reading that settles it on any recording is
    /// the rate on `Created aggregate device` against the rate on `Mic hardware
    /// format`, plus whether an `Audio format:` line follows at all. On a
    /// transition invisible to the microphone side, `Measured rate … differs
    /// from cached` is the only place it shows.
    ///
    /// Three costs, accepted rather than fixed here. A slow first microphone open
    /// now delays app capture by that much, and since a *first* start is bounded
    /// by no deadline (only restarts are, issue #588), a microphone open that
    /// wedges now prevents app capture outright where it used to leave a running
    /// tap behind it. A device change mid-recording restarts the two channels
    /// independently, so the same race stays reachable there. And an app-only
    /// recording opens no microphone at all, so the ordering buys it nothing:
    /// the meeting app opening its own input is the same trigger in the same
    /// window, which only a delivery check after the fact would catch.
    public func start() throws {
        guard config.appOutputURL != nil || config.micOutputURL != nil else {
            throw AudioCaptureSessionError.noTracksRequested
        }

        // Ahead of both channels, because it is the one app-track precondition
        // that cannot touch the audio route. Failing it here costs nothing;
        // failing it after the microphone was open would have raised the
        // first-run microphone prompt and lit the recording indicator for a
        // recording that then never starts.
        var appFile: FileHandle?
        do {
            // Inside the `do` so that its own half-done state is cleaned up too:
            // the file is created before the descriptor is opened, and an open
            // that fails on a file that was created would otherwise leave the
            // empty temp behind. Both discards are no-ops when nothing was made.
            appFile = try openAppOutputFile()
            try startMicCapture()
            try startAppCapture(writingTo: appFile)
        } catch {
            // Unlike before the reorder, a failed tap can have a running
            // microphone behind it. Everything this start opened goes back.
            discardMicCapture()
            discardAppOutputFile(appFile)
            throw error
        }

        logger.info("Capture session started (PIDs \(self.config.pids), rate: \(self.config.sampleRate), channels: \(self.config.channels))")
    }

    /// Create the app track's output file and open a descriptor onto it, or nil
    /// when no app track was requested.
    private func openAppOutputFile() throws -> FileHandle? {
        guard let appOutputURL = config.appOutputURL else { return nil }

        // Restrict permissions to owner-only (0600): audio may contain
        // sensitive meeting content. No `setAttributes` follow-up, unlike the
        // microphone's WAV, because none is needed. The documentation does not
        // say whether these attributes apply when an existing file is
        // overwritten, and it was measured that they do: a 0644 temp comes back
        // 0600 after this call (macOS 26). Adding the follow-up anyway would be
        // a line no test could tell from its absence.
        FileManager.default.createFile(
            atPath: appOutputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        )
        return try FileHandle(forWritingTo: appOutputURL)
    }

    /// Open the microphone, when one was asked for.
    ///
    /// A failure is swallowed when an app track is *also* being recorded: what
    /// is left is a degradation, and the recording is still worth keeping.
    /// Without an app track the microphone IS the recording, so the same
    /// swallow would hand back a session that captures nothing while reporting
    /// success.
    ///
    /// The condition is "an app track was requested", not "an app capture is
    /// running". Those were the same question while the tap came up first; the
    /// tap now comes up after this, so there is never one running here.
    private func startMicCapture() throws {
        guard let micURL = config.micOutputURL else { return }

        micFileWasAbsentBeforeStart = !FileManager.default.fileExists(atPath: micURL.path)
        let mic = MicCaptureHandler(
            outputURL: micURL,
            debugLogging: config.debugLogging,
            liveSink: config.micLiveSink,
            debugFault: config.micDebugFault,
            // `MicCaptureHandler`'s own convenience init builds the same
            // session, and going through it would mean restating this call's
            // four arguments in a second branch. The cost of not doing so: its
            // default is no longer on any production path, so changing the
            // session it builds would leave this line on the old one. It cannot
            // be collapsed the other way either, since a public init may not
            // name an internal protocol.
            sessionFactory: micSessionFactory ?? { MicEngineSession() },
        )
        // Stored before the start rather than after it, so that both ways out of
        // here tear down through `discardMicCapture` instead of one of them
        // repeating what it does. The stop that follows on the failure path is
        // deliberate rather than load-bearing: `deinit` would reach the same
        // teardown when the local goes out of scope, which is why no test can
        // separate the two. Releasing a device is not something to leave to a
        // release that happens to be prompt.
        micCapture = mic
        do {
            try mic.start(deviceUID: config.micDeviceUID)
            mic.onGiveUp = { [weak self] in self?.micCaptureGaveUp = true }
        } catch {
            // `MicCaptureHandler` creates its WAV part-way through starting, so
            // a failure can leave one behind.
            discardMicCapture()
            guard config.appOutputURL != nil else { throw error }
            // "Will continue", not "continuing": the tap has not been
            // attempted yet and can still fail after this line.
            logger.error("Failed to start mic capture: \(error.localizedDescription, privacy: .public). Will continue with app audio only.")
        }
    }

    /// Bring the app-audio tap up on the descriptor opened for it, or do nothing
    /// when no app track was requested. Throws: with an app track requested it is
    /// the primary one, so a tap that cannot start fails the session rather than
    /// degrading it.
    private func startAppCapture(writingTo handle: FileHandle?) throws {
        guard let handle else { return }

        let capture = AppAudioCapture(
            pids: config.pids,
            outputFileDescriptor: handle.fileDescriptor,
            sampleRate: config.sampleRate,
            channels: config.channels,
            debugLogging: config.debugLogging,
            liveSink: config.appLiveSink,
            attemptBody: appAttemptBody,
        )
        try capture.start()
        appFileHandle = handle
        capture.onGiveUp = { [weak self] in self?.appCaptureGaveUp = true }
        appCapture = capture
    }

    /// Stop a microphone this start opened and remove the file it created.
    private func discardMicCapture() {
        guard let mic = micCapture else { return }

        mic.stop()
        micCapture = nil

        // Removing the file is the point rather than tidiness: nothing
        // downstream reads a microphone track the result does not report, and no
        // cleanup pass collects one either, since `cleanupTempFiles` and the
        // crash recovery both key on a raw app temp that a discarded start does
        // not leave behind.
        //
        // Only a path that was free when this start reached it is removed, which
        // covers exactly one arm: a failure before `MicCaptureHandler` opens its
        // WAV. Past that point the handler has already truncated whatever was
        // there, so what the check preserves is a header-only husk rather than
        // the caller's recording. Worth having for the arm it does cover, and
        // worth not claiming more.
        guard micFileWasAbsentBeforeStart, let micURL = config.micOutputURL else { return }

        try? FileManager.default.removeItem(at: micURL)
    }

    /// Close the app track's descriptor and remove the file it was opened on.
    ///
    /// No ownership check here, unlike the microphone's, and the asymmetry has a
    /// reason: `createFile` has already truncated whatever was at that path, so
    /// there is no caller's recording left to spare. The microphone's file may
    /// genuinely be untouched, which is why that side checks.
    ///
    /// That file is this start's own, `openAppOutputFile` having created it, and
    /// an empty one left behind is exactly the signature crash recovery looks
    /// for: a raw app temp with no mix beside it. It would be picked up at the
    /// next launch, fail to recover, and be reported as a lost recording.
    private func discardAppOutputFile(_ handle: FileHandle?) {
        try? handle?.close()
        guard let appOutputURL = config.appOutputURL else { return }

        try? FileManager.default.removeItem(at: appOutputURL)
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

    /// How long ago the app-audio channel last delivered a buffer, and last
    /// delivered one carrying signal. `.unknown` when the channel was never
    /// opened, which the level cannot express (it reports -120 for that, for a
    /// muted device and for a dead tap alike).
    public var appSignalAges: ChannelSignalAges {
        appCapture?.currentSignalAges ?? .unknown
    }

    /// The microphone counterpart of `appSignalAges`.
    public var micSignalAges: ChannelSignalAges {
        micCapture?.currentSignalAges ?? .unknown
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
