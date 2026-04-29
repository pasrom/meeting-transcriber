import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "AppAudioCapture")

/// Captures app audio via CATapDescription (macOS 14.2+, CoreAudio).
/// No Screen Recording permission needed — only Audio Capture.
/// Monitors default output device changes and recreates the tap when needed.
@available(macOS 14.2, *)
public class AppAudioCapture {
    private let pid: pid_t
    private let sampleRate: Int
    private let channels: Int
    private let outputFileDescriptor: Int32
    private let debugLogging: Bool
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false
    private var outputListenerInstalled = false
    /// Stored listener block so we can pass the same instance to remove.
    private var outputDeviceChangeListener: AudioObjectPropertyListenerBlock?
    private let writeQueue = DispatchQueue(
        label: "audiotap.writer", qos: .userInteractive,
    )

    private var debugRMS = DebugRMSReporter()
    private var debugTotalBytes: UInt64 = 0

    /// CoreAudio property address for default output device changes.
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    /// mach_absolute_time() of first audio callback.
    public private(set) var appFirstFrameTime: UInt64 = 0
    /// Actual sample rate of the aggregate device (may differ from requested).
    public private(set) var actualSampleRate: Int = 0
    /// Actual channel count detected from first IOProc callback.
    public private(set) var actualChannels: Int = 0
    private var didLogFormat = false
    /// Guard against re-entrant device change handling during async restart.
    private var isRestarting = false

    /// - Parameters:
    ///   - pid: Process ID of the app to capture audio from.
    ///   - outputFileDescriptor: File descriptor to write raw PCM data to.
    ///   - sampleRate: Desired sample rate (default 48000).
    ///   - channels: Number of audio channels (default 2).
    ///   - debugLogging: When true, emit verbose forensic logs (process identity,
    ///     output device, periodic RMS energy of captured samples).
    public init(
        pid: pid_t,
        outputFileDescriptor: Int32,
        sampleRate: Int = 48000,
        channels: Int = 2,
        debugLogging: Bool = false,
    ) {
        self.pid = pid
        self.outputFileDescriptor = outputFileDescriptor
        self.sampleRate = sampleRate
        self.channels = channels
        self.debugLogging = debugLogging
    }

    /// Translate PID to CoreAudio process AudioObjectID.
    private func translatePID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePid = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &mutablePid, &size, &objectID,
        )
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw NSError(
                domain: "audiotap", code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to translate PID \(pid) to audio object (status: \(status))",
                ],
            )
        }
        return objectID
    }

    public func start() throws {
        try startCapture()
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
        // 1. Query the tap directly — most authoritative
        let tapRate = queryTapSampleRate(tapID: tapID)
        if tapRate > 0 {
            let validated = SampleRateQuery.validateSampleRate(
                queriedRate: tapRate, requestedRate: requestedRate,
            )
            if validated.source == .queriedDiffersFromRequested {
                logger.warning("Tap rate \(tapRate) Hz differs from requested \(requestedRate) Hz")
            }
            logger.info("Using tap format rate: \(tapRate) Hz")
            return validated.rate
        }

        // 2. Fallback: nominal + stream cross-validation
        let nominalRate = queryNominalSampleRate(deviceID: deviceID)
        let streamRate = queryStreamSampleRate(deviceID: deviceID)

        let crossCheck = SampleRateQuery.crossValidateRate(
            nominalRate: nominalRate,
            streamRate: streamRate,
        )

        let bestRate: Int
        switch crossCheck {
        case let .consistent(rate):
            bestRate = rate

        case let .mismatch(nominal, stream):
            // Prefer nominal over stream — stream on output scope can return BT HFP rate
            logger.warning("Rate mismatch: nominal=\(nominal), stream=\(stream) — using nominal rate (stream scope may reflect BT HFP)")
            bestRate = nominal

        case let .onlyNominal(rate):
            bestRate = rate

        case let .onlyStream(rate):
            bestRate = rate

        case .neitherAvailable:
            logger.warning("Cannot query sample rate, using requested \(requestedRate) Hz")
            return requestedRate
        }

        let validated = SampleRateQuery.validateSampleRate(
            queriedRate: bestRate, requestedRate: requestedRate,
        )
        if validated.source == .queriedDiffersFromRequested {
            logger.warning("Aggregate device rate \(bestRate) Hz differs from requested \(requestedRate) Hz")
        }
        return validated.rate
    }

    // swiftlint:disable:next function_body_length
    private func startCapture() throws {
        let processObjectID = try translatePID()
        logger.info("Process audio object ID: \(processObjectID)")

        if debugLogging {
            let bundleID = getProcessBundleID(processObjectID) ?? "?"
            let exeName = getExecutableName(pid: pid)
            logger.info(
                "[debug] Tap target: pid=\(self.pid, privacy: .public) exe=\(exeName, privacy: .public) bundle=\(bundleID, privacy: .public) audioObjectID=\(processObjectID, privacy: .public)",
            )
        }

        // Get default output device UID
        guard let systemOutputUID = getDefaultOutputDeviceUID() else {
            throw NSError(
                domain: "audiotap", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot get default output device UID"],
            )
        }
        logger.info("System output device: \(systemOutputUID)")

        if debugLogging {
            let deviceName = getDefaultOutputDeviceName() ?? "?"
            let transport = getDefaultOutputDeviceTransportType() ?? "?"
            let deviceRate = getDefaultOutputDeviceSampleRate() ?? 0
            logger.info(
                "[debug] Default output device: name=\(deviceName, privacy: .public) uid=\(systemOutputUID, privacy: .public) transport=\(transport, privacy: .public) rate=\(deviceRate, privacy: .public)",
            )
        }

        // Create CATapDescription for the target process
        let tap = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tap.uuid = UUID()
        tap.name = "MeetingTranscriber-tap"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tap, &newTapID)
        guard tapStatus == noErr else {
            throw NSError(
                domain: "audiotap", code: Int(tapStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to create process tap (status: \(tapStatus))",
                ],
            )
        }
        tapID = newTapID
        logger.info("Created process tap: \(self.tapID)")

        if debugLogging {
            let tapRate = Self.queryTapSampleRate(tapID: tapID)
            logger.info(
                "[debug] Tap format: rate=\(tapRate, privacy: .public) Hz, tapID=\(self.tapID, privacy: .public)",
            )
        }

        // Create aggregate device with the tap
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "audiotap-\(pid)",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: systemOutputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: systemOutputUID],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ],
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(
            desc as CFDictionary, &newAggregateID,
        )
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw NSError(
                domain: "audiotap", code: Int(aggStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to create aggregate device (status: \(aggStatus))",
                ],
            )
        }
        aggregateID = newAggregateID
        logger.info("Created aggregate device: \(self.aggregateID)")

        // Set up IOProc to read audio data and write to file descriptor
        let fd = outputFileDescriptor
        var newProcID: AudioDeviceIOProcID?
        let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, writeQueue,
        ) { [weak self] _, inInputData, _, _, _ in
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
                let measuredRate = Self.queryActualSampleRate(deviceID: self.aggregateID)
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

            // CATapDescription delivers interleaved float32 — write directly
            guard let data = abl.mBuffers.mData else { return }
            let byteCount = Int(abl.mBuffers.mDataByteSize)
            writeAllToFileHandle(fd, data, count: byteCount)

            if self.debugLogging {
                self.accumulateDebugRMS(data: data, byteCount: byteCount)
                self.maybeReportDebugRMS()
            }
        }

        guard ioProcStatus == noErr, let validProcID = newProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw NSError(
                domain: "audiotap", code: Int(ioProcStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to create IOProc (status: \(ioProcStatus))",
                ],
            )
        }
        procID = validProcID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw NSError(
                domain: "audiotap", code: Int(startStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to start audio device (status: \(startStatus))",
                ],
            )
        }

        isRunning = true

        actualSampleRate = Self.resolveActualSampleRate(
            deviceID: aggregateID, tapID: tapID, requestedRate: sampleRate,
        )
        logger.info("Audio capture started (PID \(self.pid), rate: \(self.actualSampleRate) Hz)")
    }

    private func stopCapture() {
        isRunning = false

        if debugLogging {
            logger.info(
                "[debug] App audio capture stopping: totalBytes=\(self.debugTotalBytes, privacy: .public)",
            )
        }

        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        didLogFormat = false
    }

    public func stop() {
        stopCapture()
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

// MARK: - Output device change handling

@available(macOS 14.2, *)
extension AppAudioCapture {
    func installOutputDeviceChangeListener() {
        guard !outputListenerInstalled else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleOutputDeviceChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            listener,
        )
        if status == noErr {
            outputDeviceChangeListener = listener
            outputListenerInstalled = true
            logger.info("App audio: listening for default output device changes")
        }
    }

    func handleOutputDeviceChanged() {
        guard isRunning, !isRestarting else { return }
        isRestarting = true
        logger.info("App audio: default output device changed, recreating tap...")

        if debugLogging {
            let newName = getDefaultOutputDeviceName() ?? "?"
            let newUID = getDefaultOutputDeviceUID() ?? "?"
            logger.info(
                "[debug] Output device change → name=\(newName, privacy: .public) uid=\(newUID, privacy: .public)",
            )
        }

        stopCapture()

        // USB devices need time to settle their format after connection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            do {
                try self.startCapture()
                // Verify rate was detected — USB devices may not have settled yet
                if self.actualSampleRate <= 0 {
                    logger.warning("App audio: rate query returned 0 after restart, retrying in 1s...")
                    self.stopCapture()
                    self.retryStartCapture(afterDelay: 1.0)
                } else {
                    self.isRestarting = false
                    logger.info("App audio: tap restarted on new device (rate: \(self.actualSampleRate) Hz)")
                }
            } catch {
                logger.error("Failed to restart app audio capture: \(error)")
                self.retryStartCapture(afterDelay: 1.0)
            }
        }
    }

    func retryStartCapture(afterDelay delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            defer { self.isRestarting = false }
            do {
                try self.startCapture()
                logger.info("App audio: tap restarted on retry (rate: \(self.actualSampleRate) Hz)")
            } catch {
                logger.error("Retry also failed: \(error)")
            }
        }
    }
}

// MARK: - Debug logging helpers

@available(macOS 14.2, *)
extension AppAudioCapture {
    /// Called from the IOProc (serial writeQueue) only when debugLogging=true.
    /// Sums squares of the interleaved Float32 buffer into the shared RMS reporter.
    func accumulateDebugRMS(data: UnsafeMutableRawPointer, byteCount: Int) {
        let count = byteCount / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let buf = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self), count: count,
        )
        var sumSq: Double = 0
        for sample in buf {
            sumSq += Double(sample) * Double(sample)
        }
        debugRMS.add(sumSq: sumSq, samples: count)
        debugTotalBytes += UInt64(byteCount)
    }

    /// Emit a single RMS-energy log line every ~5 s of capture.
    /// Live signal whether the tap is delivering real audio or zero/noise.
    func maybeReportDebugRMS() {
        guard let report = debugRMS.tick() else { return }
        let dBStr = String(format: "%.1f", report.dBFS)
        logger.info(
            "[debug] App audio RMS (5s): \(dBStr, privacy: .public) dBFS, samples=\(report.samples, privacy: .public), totalBytes=\(self.debugTotalBytes, privacy: .public)",
        )
    }
}
