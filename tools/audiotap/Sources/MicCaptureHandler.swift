import AVFoundation
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// Records microphone audio to a WAV file via AVAudioEngine.
/// Monitors for default input device changes (e.g. AirPods connected) via
/// CoreAudio property listener and automatically restarts the engine.
public class MicCaptureHandler {
    private var engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private let outputURL: URL
    private var isRecording = false
    private var listenerInstalled = false
    /// Stored listener block so we can pass the same instance to remove.
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    /// Sample rate of the WAV file (set on first start, stays fixed).
    private var fileSampleRate: Double = 0
    /// Resampler for when device sample rate differs from file sample rate.
    private var converter: AVAudioConverter?
    /// mach_absolute_time() of first audio callback.
    public private(set) var firstFrameTime: UInt64 = 0

    /// CoreAudio property address for default input device changes.
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    public init(outputURL: URL) {
        self.outputURL = outputURL
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
        try startEngine(deviceUID: deviceUID)
        installDeviceChangeListener()
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

        // Create WAV file on first start; always at 16kHz (WhisperKit target rate).
        // The AVAudioConverter below handles resampling from any hardware rate.
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

        // Set up resampler if device sample rate differs from file sample rate
        converter = nil
        if tapFormat.sampleRate != fileSampleRate {
            let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: fileSampleRate, channels: 1,
            )! // swiftlint:disable:this force_unwrapping
            converter = AVAudioConverter(from: tapFormat, to: outputFormat)
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
                    // Resample to match the WAV file's sample rate
                    let ratio = self.fileSampleRate / tapFormat.sampleRate
                    let outputFrames = AVAudioFrameCount(
                        Double(buffer.frameLength) * ratio,
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

    /// Listen for default input device changes via CoreAudio property listener.
    private func installDeviceChangeListener() {
        guard !listenerInstalled else { return }
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
            listenerInstalled = true
            logger.info("Mic: listening for default input device changes")
        } else {
            logger.warning("Failed to install device change listener (status: \(status))")
        }
    }

    private func handleDefaultInputDeviceChanged() {
        guard isRecording else { return }
        logger.info("Mic: default input device changed, restarting engine...")

        // Stop current engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        // Create a fresh engine (AVAudioEngine can be in a bad state after config change)
        engine = AVAudioEngine()

        // Restart with new system default
        do {
            try startEngine(deviceUID: nil)
            logger.info("Mic: engine restarted on new default device")
        } catch {
            logger.error("Failed to restart mic after device change: \(error)")
        }
    }

    public func stop() {
        isRecording = false
        if listenerInstalled, let listener = deviceChangeListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                listener,
            )
            deviceChangeListener = nil
            listenerInstalled = false
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        outputFile = nil
        logger.info("Mic recording stopped")
    }
}
