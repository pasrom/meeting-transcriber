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

    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    public init(outputURL: URL) {
        self.outputURL = outputURL
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
            installConfigChangeObserver()
            logger.info("Mic: engine restarted on \(deviceUID != nil ? "selected" : "default") device")
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
