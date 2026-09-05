import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

/// Captures app audio via CATapDescription (macOS 14.2+, CoreAudio).
/// No Screen Recording permission needed — only Audio Capture.
/// Monitors default output device changes and recreates the tap when needed.
///
/// Most mutable state is serialized through `writeQueue` (`audiotap.writer`,
/// userInteractive QoS) or driven from the CoreAudio IOProc callback which
/// never overlaps with itself for a given tap. The two fields the main thread
/// and the IOProc genuinely touch concurrently — `actualSampleRate` and
/// `isRunning` — are instead `OSAllocatedUnfairLock`-backed so each access is
/// atomic. `@unchecked Sendable` reflects that this serialization is manual
/// rather than expressible to the compiler.
@available(macOS 14.2, *)
public class AppAudioCapture: @unchecked Sendable {
    /// `internal` (not `private`) so the cross-file `+PIDTranslation`
    /// extension can read it; it's not otherwise touched from outside.
    let pids: [pid_t]
    /// `sampleRate` and `liveSink` are `internal` (not `private`) so the
    /// cross-file `+LiveSink` extension can populate the live buffer struct.
    let sampleRate: Int
    private let channels: Int
    private let outputFileDescriptor: Int32
    /// `internal` (not `private`) so the cross-file `+DebugLogging` extension
    /// can drive the throttled dBFS log line.
    let debugLogging: Bool
    let liveSink: LiveAudioSink?
    /// Resamples + downmixes each captured buffer to 16 kHz mono in the IOProc
    /// (issue #379 follow-up — see `writeCapturedBuffer` in `+Resampling`).
    /// `internal` (not `private`) so that cross-file extension can reach it.
    /// `nil` only if a 16 kHz output format couldn't be built (not expected);
    /// the write then falls back to the raw native-rate path.
    let resampler: StreamingMonoResampler?
    /// Wall-clock anchoring so an output-device-restart gap becomes silence in
    /// the file instead of an under-run that drifts against the mic track (issue
    /// #379 follow-up — see `writeCapturedBuffer` in `+Resampling`). `internal`
    /// for that cross-file extension; touched only on `writeQueue`.
    var timelineAnchor = TimelineAnchor(rate: Int(speechSampleRate))
    /// What the currently installed attempt built, or nil while nothing is
    /// installed. Main-queue confined: only `start()`, the restart adoption and
    /// `stopCapture` touch it, and all three run there. An attempt in flight
    /// holds its own session locally and never reads this.
    private var tapSession: AppTapSession?
    /// Gates the IOProc callback (read on `writeQueue`), set on the start/stop
    /// path on the main thread. It is set only by `start()` and by the restart
    /// adoption, never by `startCapture` itself, and must follow `AudioDeviceStart`,
    /// so it can't be reordered ahead of the callback's read — hence an atomic lock.
    private let runningLock = OSAllocatedUnfairLock(initialState: false)
    var isRunning: Bool {
        get { runningLock.withLock { $0 } }
        set { runningLock.withLock { $0 = newValue } }
    }

    var outputListenerInstalled = false
    /// Stored listener block so we can pass the same instance to remove.
    var outputDeviceChangeListener: AudioObjectPropertyListenerBlock?
    private let writeQueue = DispatchQueue(
        label: "audiotap.writer", qos: .userInteractive,
    )

    /// `internal` (not `private`) so the cross-file `+DebugLogging` extension
    /// can drive the per-buffer RMS accumulator + dBFS report cadence.
    /// Issue #672; see `AppAudioCapture+SilentTrackDiagnostics`.
    let silentTrackDiagnostics = SilentTrackDiagnostics(sink: AppAudioCapture.logSilentTrackProbe)

    var debugRMS = DebugRMSReporter()
    var debugTotalBytes: UInt64 = 0
    let levelPublisher = LevelPublisher()

    /// Returns the instantaneous app-audio level in dBFS, decayed to -120 if
    /// no buffer arrived in the last 0.5 seconds (e.g. tap died, device
    /// unplugged) — without that, a stale reading would look like live audio.
    public var currentLevelDBFS: Double {
        levelPublisher.currentLevelDBFS
    }

    /// See `ChannelSignalAges`: the level alone folds "no buffers", "buffers of
    /// zeroes" and "a real but very quiet buffer" into one number.
    public var currentSignalAges: ChannelSignalAges {
        levelPublisher.currentSignalAges
    }

    /// CoreAudio property address for default output device changes.
    var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    /// mach_absolute_time() of first audio callback.
    public private(set) var appFirstFrameTime: UInt64 = 0
    /// Actual sample rate of the aggregate device (may differ from requested).
    /// Touched by the IOProc (`writeQueue`) and the main thread (start/restart
    /// logs, restart event), so it is `OSAllocatedUnfairLock`-backed for atomic
    /// cross-thread access; `private(set)` keeps writes internal.
    private let actualSampleRateLock = OSAllocatedUnfairLock(initialState: 0)
    public private(set) var actualSampleRate: Int {
        get { actualSampleRateLock.withLock { $0 } }
        set { actualSampleRateLock.withLock { $0 = newValue } }
    }

    /// Actual channel count detected from first IOProc callback.
    public private(set) var actualChannels: Int = 0
    // `outputSampleRate` / `outputChannels` (the format actually written to the
    // fd, 16 kHz mono after the in-IOProc resample) live in `+Resampling`.

    private var didLogFormat = false
    /// Pure state machine that decides when/what to dispatch on device-change events.
    var deviceChangeCoordinator = OutputDeviceChangeCoordinator()

    /// Bounds a single restart attempt (issue #588). The coordinator above decides
    /// *what* a device change should do and how many times; this decides how long
    /// one attempt may take before it counts as never returning.
    let restartArbiter = OSAllocatedUnfairLock(initialState: RestartArbiter())

    /// Restart attempts run here, never on the main queue. `startCapture` is a
    /// chain of HAL calls through the same coreaudiod that can stop answering,
    /// and on the main queue a stuck one takes the whole app down.
    let restartQueue = DispatchQueue(
        label: "com.meetingtranscriber.audiotap.app-restart",
        qos: .userInitiated,
    )

    /// The work one attempt performs. Injectable so a test can substitute a call
    /// that blocks the way a wedged HAL call does; nil means the real thing.
    private let attemptBody: (() throws -> AppTapSession?)?

    /// Called when app-audio capture was abandoned, either because a restart
    /// attempt exceeded its deadline or because the retry budget ran out.
    public var onGiveUp: (() -> Void)?

    /// - Parameters:
    ///   - pids: Process IDs to capture audio from. Pass the meeting app's
    ///     root PID plus its helper/renderer child PIDs for Electron-based
    ///     apps (Teams 2.x, Slack, Discord); pass a single-element array
    ///     for native Cocoa apps. Helpers whose `translatePIDToProcessObject`
    ///     lookup fails (no audio-object entry) are skipped silently.
    ///   - outputFileDescriptor: File descriptor to write raw PCM data to.
    ///   - sampleRate: Desired sample rate (default 48000).
    ///   - channels: Number of audio channels (default 2).
    ///   - debugLogging: When true, emit verbose forensic logs (process identity,
    ///     output device, periodic RMS energy of captured samples).
    ///   - liveSink: Optional callback receiving a copy of each captured buffer.
    ///     Called on the audio IOProc thread — must not block. Nil = no-op,
    ///     existing batch path unchanged.
    public convenience init(
        pids: [pid_t],
        outputFileDescriptor: Int32,
        sampleRate: Int = 48000,
        channels: Int = 2,
        debugLogging: Bool = false,
        liveSink: LiveAudioSink? = nil,
    ) {
        self.init(
            pids: pids,
            outputFileDescriptor: outputFileDescriptor,
            sampleRate: sampleRate,
            channels: channels,
            debugLogging: debugLogging,
            liveSink: liveSink,
            attemptBody: nil,
        )
    }

    /// Test seam. Deliberately not `public`: same-module tests substitute the
    /// hardware work so the restart choreography can be exercised on a machine
    /// with no audio device, and made to block so the deadline can be observed.
    init(
        pids: [pid_t],
        outputFileDescriptor: Int32,
        sampleRate: Int = 48000,
        channels: Int = 2,
        debugLogging: Bool = false,
        liveSink: LiveAudioSink? = nil,
        attemptBody: (() throws -> AppTapSession?)?,
    ) {
        self.pids = pids
        self.outputFileDescriptor = outputFileDescriptor
        self.sampleRate = sampleRate
        self.channels = channels
        self.debugLogging = debugLogging
        self.liveSink = liveSink
        self.attemptBody = attemptBody
        resampler = StreamingMonoResampler(targetRate: Int(speechSampleRate))
    }

    /// One attempt's worth of work: bring the tap up, or whatever a test injected.
    func performAttempt() throws -> AppTapSession? {
        if let attemptBody {
            return try attemptBody()
        }
        return try startCapture()
    }

    /// Install what an attempt built and publish its rate. The only two callers
    /// are `start()` and the restart adoption, which is what keeps a returning
    /// stale attempt from resurrecting capture.
    ///
    /// Caller guarantees nothing is installed: both callers follow a stop in the
    /// same cycle. Taking a non-optional keeps "a successful attempt built
    /// something" a fact the type system carries rather than a convention.
    func install(_ session: AppTapSession) {
        tapSession = session
        silentTrackDiagnostics.remember(session.tappedProcesses)
        actualSampleRate = session.resolvedSampleRate
    }

    public func start() throws {
        // Only the test seam returns nothing: production startCapture either
        // hands back a session or throws.
        if let built = try performAttempt() { install(built) }
        // startCapture deliberately no longer sets this. Declaring capture
        // running belongs to start() and to the restart adoption, so an attempt
        // that returns after a give-up cannot do it.
        isRunning = true
        _ = restartArbiter.withLock { $0.handle(.startSucceeded) }
        installOutputDeviceChangeListener()
    }

    /// Query nominal sample rate from a CoreAudio device.
    private static func queryNominalSampleRate(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        if status != noErr {
            logger.warning("queryNominalSampleRate failed (status: \(status))")
            return 0
        }
        return Int(rate)
    }

    /// Query physical stream format sample rate from a CoreAudio device.
    private static func queryStreamSampleRate(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        if status != noErr {
            // Not all devices support this query — non-fatal
            return 0
        }
        return Int(asbd.mSampleRate)
    }

    /// Query the tap's own format — most authoritative source for tap data rate.
    /// Uses kAudioTapPropertyFormat which returns the ASBD the tap delivers.
    private static func queryTapSampleRate(tapID: AudioObjectID) -> Int {
        guard tapID != kAudioObjectUnknown else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        if status != noErr {
            logger.warning("queryTapSampleRate failed (status: \(status))")
            return 0
        }
        return Int(asbd.mSampleRate)
    }

    /// Query the actual measured sample rate from a running device.
    /// Only valid after AudioDeviceStart — returns the hardware-measured rate.
    private static func queryActualSampleRate(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyActualSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        if status != noErr { return 0 }
        return Int(rate)
    }

    /// Query, cross-validate, and return the best available sample rate for a device.
    /// Priority: tap format > nominal rate > stream format > requested rate.
    private static func resolveActualSampleRate(
        deviceID: AudioObjectID,
        tapID: AudioObjectID,
        requestedRate: Int,
    ) -> Int {
        // Query the tap directly first — most authoritative. Only cross-validate
        // nominal + stream when the tap has no rate, preserving the original
        // short-circuit (no extra hardware queries when the tap answers).
        let tapRate = queryTapSampleRate(tapID: tapID)
        let nominalRate = tapRate > 0 ? 0 : queryNominalSampleRate(deviceID: deviceID)
        let streamRate = tapRate > 0 ? 0 : queryStreamSampleRate(deviceID: deviceID)

        let decision = SampleRateQuery.chooseRate(
            tapRate: tapRate, nominalRate: nominalRate, streamRate: streamRate, requestedRate: requestedRate,
        )

        switch decision.source {
        case .tap:
            if decision.differsFromRequested {
                logger.warning("Tap rate \(tapRate) Hz differs from requested \(requestedRate) Hz")
            }
            logger.info("Using tap format rate: \(tapRate) Hz")
            return decision.rate

        case .requestedFallback:
            logger.warning("Cannot query sample rate, using requested \(requestedRate) Hz")
            return decision.rate

        case .mismatchPreferNominal:
            // Prefer nominal over stream — stream on output scope can return BT HFP rate
            logger.warning("Rate mismatch: nominal=\(nominalRate), stream=\(streamRate) — using nominal rate (stream scope may reflect BT HFP)")

        case .consistent, .onlyNominal, .onlyStream:
            break
        }

        // Cross-validated rungs (consistent / mismatch / onlyNominal / onlyStream):
        // flag when the queried rate the ladder picked differs from requested.
        if decision.differsFromRequested {
            logger.warning("Aggregate device rate \(decision.rate) Hz differs from requested \(requestedRate) Hz")
        }
        return decision.rate
    }

    // swiftlint:disable:next function_body_length
    private func startCapture() throws -> AppTapSession {
        let translated = try translatePIDs()
        let processObjectIDs = translated.map(\.audioObjectID)

        // Always log at info level with exe names so a "silent _app.wav"
        // report can be triaged without the user toggling Verbose Audio
        // Logging first — process names like "MSTeams Helper (Renderer)"
        // make issue-#84-style failures actionable.
        let tapSummary = translated.map { "\(getExecutableName(pid: $0.pid))(\($0.pid))" }.joined(separator: ", ")
        logger.info(
            "App audio tap: \(translated.count) PID(s) [\(tapSummary, privacy: .public)]",
        )

        if debugLogging {
            for entry in translated {
                let bundleID = getProcessBundleID(entry.audioObjectID) ?? "?"
                let exeName = getExecutableName(pid: entry.pid)
                logger.info(
                    "[debug] Tap target: pid=\(entry.pid, privacy: .public) exe=\(exeName, privacy: .public) bundle=\(bundleID, privacy: .public) audioObjectID=\(entry.audioObjectID, privacy: .public)",
                )
            }
        }

        // Get default output device UID
        guard let systemOutputUID = getDefaultOutputDeviceUID() else {
            throw NSError(
                domain: "audiotap", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot get default output device UID"],
            )
        }
        // Transport type is logged unconditionally (not personal data, unlike
        // the device name/UID): a "Virtual"/"Aggregate" transport is the first
        // sign that a third-party audio tool has interposed on the output and
        // the process tap may capture silence (issue #524).
        let transport = getDefaultOutputDeviceTransportType() ?? "?"
        logger.info("System output device: \(systemOutputUID) transport=\(transport, privacy: .public)")

        if debugLogging {
            let deviceName = getDefaultOutputDeviceName() ?? "?"
            let deviceRate = getDefaultOutputDeviceSampleRate() ?? 0
            logger.info(
                "[debug] Default output device: name=\(deviceName, privacy: .public) uid=\(systemOutputUID, privacy: .public) transport=\(transport, privacy: .public) rate=\(deviceRate, privacy: .public)",
            )
        }

        // Create CATapDescription for the target process(es). For Electron
        // apps this covers the helper tree so the renderer holding the audio
        // handle is included; for native apps the array is a single PID.
        let tap = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tap.uuid = UUID()
        tap.name = "MeetingTranscriber-tap"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tap, &newTapID)
        guard tapStatus == noErr else {
            let hint = Self.describeTapError(tapStatus)
            logger.error(
                "Failed to create process tap (pids=\(self.pids, privacy: .public)): \(hint, privacy: .public)",
            )
            throw NSError(
                domain: "audiotap", code: Int(tapStatus),
                userInfo: [NSLocalizedDescriptionKey: hint],
            )
        }
        // From here the attempt owns what it builds. Every failure below hands
        // back one object instead of remembering which of three ids it created.
        //
        // The drain captures the queue by value on purpose. A `[weak self]` drain
        // would silently skip the barrier once self is gone, which is exactly the
        // write-after-close bug the barrier exists to prevent, and a strong self
        // would make the session keep its owner alive.
        let session = AppTapSession(tapID: newTapID, tappedProcesses: translated) { [writeQueue] in
            writeQueue.sync {}
        }
        let tapRate = Self.queryTapSampleRate(tapID: newTapID)
        logger.info("Created process tap: \(newTapID) rate=\(tapRate, privacy: .public) Hz")

        if debugLogging {
            logger.info(
                "[debug] Tap format: rate=\(tapRate, privacy: .public) Hz, tapID=\(newTapID, privacy: .public)",
            )
        }

        let desc = Self.aggregateDescription(
            nameTag: pids.first.map(String.init) ?? "0",
            outputUID: systemOutputUID,
            tapUUID: tap.uuid.uuidString,
        )

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(
            desc as CFDictionary, &newAggregateID,
        )
        guard aggStatus == noErr else {
            session.destroy()
            throw NSError(
                domain: "audiotap", code: Int(aggStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to create aggregate device (status: \(aggStatus))",
                ],
            )
        }
        // Resolving the rate here rather than after the IOProc is value ordering,
        // not race-safety: it reads only the tap format and the device's
        // nominal/stream-format properties, so it is valid before the device
        // starts, and doing it now lets the session carry it. The IOProc's
        // first-callback measured correction layers on top of the published copy.
        session.attach(
            aggregateID: newAggregateID,
            resolvedSampleRate: Self.resolveActualSampleRate(
                deviceID: newAggregateID, tapID: newTapID, requestedRate: sampleRate,
            ),
        )
        logger.info("Created aggregate device: \(newAggregateID)")

        // Set up IOProc to read audio data and write to file descriptor
        let fd = outputFileDescriptor
        // The device this block belongs to, captured by value. Reading the field
        // from inside the callback would query whatever device the newest attempt
        // installed rather than the one actually delivering these buffers, so a
        // block that outlives its own attempt would correct its rate against a
        // stranger.
        var newProcID: AudioDeviceIOProcID?
        let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, newAggregateID, writeQueue,
        ) { [weak self, session] _, inInputData, inInputTime, _, _ in
            guard let self, self.isRunning else { return }
            let abl = inInputData.pointee

            // Log format on first callback
            if !self.didLogFormat {
                self.didLogFormat = true
                // Only record the very first frame time — not after device restarts.
                // MicCaptureHandler uses the same guard. Without this, a device change
                // mid-recording overwrites the timestamp, corrupting the micDelay
                // calculation and producing a mix.wav at 2× duration (see #99).
                if self.appFirstFrameTime == 0 {
                    self.appFirstFrameTime = mach_absolute_time()
                }
                self.actualChannels = Int(abl.mBuffers.mNumberChannels)

                // Device is running — query the measured actual rate
                let measuredRate = Self.queryActualSampleRate(deviceID: session.aggregateID)
                if measuredRate > 0, measuredRate != self.actualSampleRate {
                    logger.warning(
                        "Measured rate \(measuredRate) Hz differs from cached \(self.actualSampleRate) Hz — updating",
                    )
                    self.actualSampleRate = measuredRate
                }

                let ch = max(self.actualChannels, 1)
                let frames = Int(abl.mBuffers.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                logger.info(
                    "Audio format: \(self.actualSampleRate) Hz, \(self.actualChannels)ch, \(abl.mNumberBuffers) buffers, \(frames) frames/buffer",
                )
            }

            // CATapDescription delivers interleaved float32. Resample + downmix
            // to 16 kHz mono AT CAPTURE (writeCapturedBuffer, +Resampling),
            // rebuilding the converter on a mid-recording rate change so a
            // device swap can't time-warp the file the way a single post-hoc
            // resample did (issue #379 follow-up). The live sink is fed the SAME
            // resampled 16 kHz mono buffer from inside writeCapturedBuffer, so
            // the app doesn't resample a second time. RMS/level still read the
            // raw buffer below.
            guard let data = abl.mBuffers.mData else { return }
            let byteCount = Int(abl.mBuffers.mDataByteSize)
            let hostTicks = Self.hostTicks(from: inInputTime)
            self.writeCapturedBuffer(fd: fd, data: data, byteCount: byteCount, hostTicks: hostTicks)

            self.accumulateDebugRMS(data: data, byteCount: byteCount)
            self.publishCurrentLevel()
            self.maybeReportDebugRMS(processes: session.tappedProcesses)
        }

        guard ioProcStatus == noErr, let validProcID = newProcID else {
            session.destroy()
            throw NSError(
                domain: "audiotap", code: Int(ioProcStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to create IOProc (status: \(ioProcStatus))",
                ],
            )
        }
        session.attach(procID: validProcID)

        let startStatus = AudioDeviceStart(newAggregateID, validProcID)
        guard startStatus == noErr else {
            session.destroy()
            throw NSError(
                domain: "audiotap", code: Int(startStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to start audio device (status: \(startStatus))",
                ],
            )
        }

        // Deliberately does NOT declare capture running. Only start() and the
        // restart adoption may do that, so an attempt that returns after a
        // give-up cannot resurrect the IOProc against a file descriptor the
        // session has already closed.
        logger.info(
            "Audio capture started (PIDs \(self.pids), rate: \(session.resolvedSampleRate) Hz)",
        )
        silentTrackDiagnostics.probeAsync(session.tappedProcesses, reason: "start")
        return session
    }

    func stopCapture() {
        isRunning = false

        if debugLogging {
            logger.info(
                "[debug] App audio capture stopping: totalBytes=\(self.debugTotalBytes, privacy: .public)",
            )
        }

        // The session owns the release order, including the write-queue drain
        // that keeps a late buffer from writing into a descriptor the caller is
        // about to close.
        tapSession?.destroy()
        tapSession = nil
        didLogFormat = false
    }

    public func stop() {
        // Not in stopCapture, which a restart also calls. See the extension.
        logSilentTrackSummary()
        // Ask first: an attempt may be stuck inside the same coreaudiod, and every
        // HAL call below would block behind it. Safe to skip in that case because
        // an attempt is only ever launched after the coordinator already ran
        // stopCapture(), so no IOProc is live while one is outstanding.
        let decision = restartArbiter.withLock { $0.handle(.stopRequested) }
        switch decision {
        case .teardown:
            stopCapture()

        case .sealAndSkipEngine:
            logger.warning("App audio: stopping while a restart attempt is outstanding — leaving its resources alone")
            markStoppedAfterGiveUp()

        default:
            break
        }
        if outputListenerInstalled, let listener = outputDeviceChangeListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                DispatchQueue.main,
                listener,
            )
            outputDeviceChangeListener = nil
            outputListenerInstalled = false
        }
        logger.info("Audio capture stopped")
    }
}
