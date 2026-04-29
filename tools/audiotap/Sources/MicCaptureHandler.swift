import AVFoundation
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// Records microphone audio to a WAV file via AVAudioEngine.
/// Monitors for device changes via CoreAudio property listener (default input device)
/// and AVAudioEngine configuration change notification (format/route changes).
/// Automatically restarts the engine on device switch, preserving the selected device
/// when still available or falling back to system default with a warning.
public class MicCaptureHandler {
    private var engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private let outputURL: URL
    private let debugLogging: Bool
    private var isRecording = false
    private var isRestarting = false
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var configChangeObserver: NSObjectProtocol?
    private var selectedDeviceUID: String?
    private var fileSampleRate: Double = 0
    private var converter: AVAudioConverter?
    /// Pre-computed resampling ratio (fileSampleRate / tapSampleRate), avoids division in audio callback.
    private var resampleRatio: Double = 1.0
    public private(set) var firstFrameTime: UInt64 = 0

    private var debugRMS = DebugRMSReporter()

    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    public init(outputURL: URL, debugLogging: Bool = false) {
        self.outputURL = outputURL
        self.debugLogging = debugLogging
    }

    deinit {
        stop()
    }

    private static func deviceIDForUID(_ uid: String) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID: Unmanaged<CFString>? = Unmanaged.passUnretained(uid as CFString)
        let qualifierSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, qualifierSize, &cfUID,
            &size, &deviceID,
        )
        return deviceID
    }

    public func start(deviceUID: String? = nil) throws {
        selectedDeviceUID = deviceUID
        try startEngine(deviceUID: deviceUID)
        installDeviceChangeListener()
        installConfigChangeObserver()
    }

    // swiftlint:disable:next function_body_length
    private func startEngine(deviceUID: String? = nil) throws {
        // No input device available (e.g. Mac Mini server without mic hardware) —
        // accessing AVAudioEngine.inputNode would throw an uncatchable NSException.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw MicCaptureError.noInputDevice
        }

        let inputNode = engine.inputNode

        if let uid = deviceUID {
            var deviceID = Self.deviceIDForUID(uid)
            if deviceID != kAudioObjectUnknown {
                let audioUnit = inputNode.audioUnit! // swiftlint:disable:this force_unwrapping
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size),
                )
                logger.info("Mic device set: \(uid) (ID \(deviceID))")
            } else {
                logger.warning("Unknown mic device UID '\(uid)', using default")
            }
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Mic hardware format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount)ch")

        if debugLogging {
            let inUID = getDefaultInputDeviceUID() ?? "?"
            let inName = getDefaultInputDeviceName() ?? "?"
            logger.info(
                "[debug] Mic input device: name=\(inName, privacy: .public) uid=\(inUID, privacy: .public) hwRate=\(hwFormat.sampleRate, privacy: .public) hwChannels=\(hwFormat.channelCount, privacy: .public)",
            )
        }

        let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: hwFormat.sampleRate, channels: 1,
        )! // swiftlint:disable:this force_unwrapping
        logger.info("Mic tap format: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount)ch")

        // Always 16kHz — WhisperKit target rate
        if outputFile == nil {
            fileSampleRate = speechSampleRate
            let wavSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: fileSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            outputFile = try AVAudioFile(forWriting: outputURL, settings: wavSettings)
            // Restrict permissions to owner-only (0600) — audio may contain sensitive meeting content
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path,
            )
        }

        converter = nil
        resampleRatio = 1.0
        if tapFormat.sampleRate != fileSampleRate {
            let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: fileSampleRate, channels: 1,
            )! // swiftlint:disable:this force_unwrapping
            converter = AVAudioConverter(from: tapFormat, to: outputFormat)
            resampleRatio = fileSampleRate / tapFormat.sampleRate
            logger.info("Mic: resampling \(Int(tapFormat.sampleRate))→\(Int(self.fileSampleRate)) Hz")
        }

        // swiftlint:disable closure_parameter_position closure_body_length
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) {
            [weak self] buffer, _ in
            // swiftlint:enable closure_parameter_position closure_body_length
            guard let self else { return }
            if self.firstFrameTime == 0 {
                self.firstFrameTime = mach_absolute_time()
            }
            if self.debugLogging {
                self.accumulateDebugRMS(buffer: buffer)
                self.maybeReportDebugRMS()
            }
            do {
                if let converter = self.converter {
                    let outputFrames = AVAudioFrameCount(
                        Double(buffer.frameLength) * self.resampleRatio,
                    )
                    guard let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: converter.outputFormat,
                        frameCapacity: outputFrames,
                    ) else { return }
                    var error: NSError?
                    var consumed = false
                    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                        if consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if let error {
                        logger.warning("Mic resample error: \(error)")
                    } else {
                        try self.outputFile?.write(from: outputBuffer)
                    }
                } else {
                    try self.outputFile?.write(from: buffer)
                }
            } catch {
                logger.warning("Mic write error: \(error)")
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        logger.info("Mic recording started: \(self.outputURL.lastPathComponent)")
    }

    private func installDeviceChangeListener() {
        guard deviceChangeListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputDeviceChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            listener,
        )
        if status == noErr {
            deviceChangeListener = listener
            logger.info("Mic: listening for default input device changes")
        } else {
            logger.warning("Failed to install device change listener (status: \(status))")
        }
    }

    /// Listen for AVAudioEngine configuration changes (format changes on current device).
    private func installConfigChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main,
        ) { [weak self] _ in
            self?.handleEngineConfigChange()
        }
        logger.info("Mic: listening for engine configuration changes")
    }

    private func handleEngineConfigChange() {
        logger.info("Mic: engine configuration changed (format/route change)")
        handleDeviceChange()
    }

    private func handleDefaultInputDeviceChanged() {
        logger.info("Mic: default input device changed")
        handleDeviceChange()
    }

    private func handleDeviceChange() {
        let isDeviceAvailable = selectedDeviceUID.map { Self.deviceIDForUID($0) != kAudioObjectUnknown } ?? false
        let action = MicRestartPolicy.decideRestart(
            isRecording: isRecording,
            isRestarting: isRestarting,
            selectedDeviceUID: selectedDeviceUID,
            isSelectedDeviceAvailable: isDeviceAvailable,
        )

        switch action {
        case let .restart(deviceUID):
            executeRestart(deviceUID: deviceUID)

        case .skip:
            break
        }
    }

    private func executeRestart(deviceUID: String?) {
        isRestarting = true
        defer { isRestarting = false }

        if deviceUID == nil, let uid = selectedDeviceUID {
            logger.warning("Mic: selected device '\(uid)' no longer available, falling back to system default")
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // AVAudioEngine can be in a bad state after config change — must recreate
        engine = AVAudioEngine()

        do {
            try startEngine(deviceUID: deviceUID)
            let hwRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
            if hwRate <= 0 {
                logger.warning("Mic: hardware format rate is \(hwRate) after restart — may produce incorrect audio")
            }
            installConfigChangeObserver()
            logger.info("Mic: engine restarted on \(deviceUID != nil ? "selected" : "default") device (\(Int(hwRate)) Hz)")
        } catch {
            isRecording = false
            logger.error("Failed to restart mic after device change: \(error)")
        }
    }

    public func stop() {
        isRecording = false
        if let listener = deviceChangeListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                listener,
            )
            deviceChangeListener = nil
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        outputFile = nil
        logger.info("Mic recording stopped")
    }
}

// MARK: - Debug logging helpers

extension MicCaptureHandler {
    /// Sum squares across all channels of an AVAudioPCMBuffer into the shared
    /// reporter. AVAudioEngine taps deliver float buffers in practice; the int16
    /// branch is a safety net.
    func accumulateDebugRMS(buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        let sumSq: Double
        if let floatData = buffer.floatChannelData {
            sumSq = sumOfSquaresFloat(floatData, frames: frames, channels: channelCount)
        } else if let int16Data = buffer.int16ChannelData {
            sumSq = sumOfSquaresInt16(int16Data, frames: frames, channels: channelCount)
        } else {
            return
        }
        debugRMS.add(sumSq: sumSq, samples: frames * channelCount)
    }

    func maybeReportDebugRMS() {
        guard let report = debugRMS.tick() else { return }
        let dBStr = String(format: "%.1f", report.dBFS)
        logger.info(
            "[debug] Mic RMS (5s): \(dBStr, privacy: .public) dBFS, samples=\(report.samples, privacy: .public)",
        )
    }
}

private func sumOfSquaresFloat(
    _ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int, channels: Int,
) -> Double {
    var sumSq: Double = 0
    for ch in 0 ..< channels {
        let ptr = data[ch]
        for i in 0 ..< frames {
            sumSq += Double(ptr[i]) * Double(ptr[i])
        }
    }
    return sumSq
}

private func sumOfSquaresInt16(
    _ data: UnsafePointer<UnsafeMutablePointer<Int16>>, frames: Int, channels: Int,
) -> Double {
    let scale = 1.0 / 32768.0
    var sumSq: Double = 0
    for ch in 0 ..< channels {
        let ptr = data[ch]
        for i in 0 ..< frames {
            let s = Double(ptr[i]) * scale
            sumSq += s * s
        }
    }
    return sumSq
}

public enum MicCaptureError: LocalizedError {
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone hardware available"
        }
    }
}
