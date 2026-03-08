import AVFoundation
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MicRecorder")

/// Records microphone audio using AVAudioEngine.
/// Outputs 48kHz mono Float32 samples to a WAV file.
@Observable
class MicRecorder {
    private var engine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private(set) var isRecording = false

    /// Start recording from the microphone to a WAV file.
    ///
    /// - Parameters:
    ///   - outputPath: Where to write the WAV file
    ///   - deviceUID: CoreAudio device UID (nil = system default)
    ///   - sampleRate: Target sample rate (default 48000)
    func start(outputPath: URL, deviceUID: String? = nil, sampleRate: Double = 48000) throws {
        let engine = AVAudioEngine()

        // Select input device if specified
        if let uid = deviceUID {
            try Self.setInputDevice(uid: uid, on: engine)
        }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        logger.info("Mic hardware format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch")

        // Output format: mono Float32 at target sample rate
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicRecorderError.formatCreationFailed
        }

        // Create output file
        let file = try AVAudioFile(
            forWriting: outputPath,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.outputFile = file

        // Install tap — AVAudioEngine handles format conversion automatically
        // when the tap format differs from the hardware format
        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self, self.isRecording else { return }
            do {
                try file.write(from: buffer)
            } catch {
                logger.error("Failed to write mic buffer: \(error)")
            }
        }

        try engine.start()
        self.engine = engine
        isRecording = true
        logger.info("Mic recording started → \(outputPath.lastPathComponent)")
    }

    /// Stop recording and return the output file URL.
    func stop() {
        guard isRecording else { return }
        isRecording = false

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        outputFile = nil
        logger.info("Mic recording stopped")
    }

    /// List available audio input devices.
    static func listDevices() -> [(uid: String, name: String, channels: UInt32)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        var results: [(uid: String, name: String, channels: UInt32)] = []
        for deviceID in deviceIDs {
            // Check input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufListSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufListSize) == noErr,
                  bufListSize > 0 else { continue }

            let bufListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufListPtr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufListSize, bufListPtr) == noErr else { continue }

            let bufList = bufListPtr.pointee
            let inputChannels = bufList.mBuffers.mNumberChannels
            guard inputChannels > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { continue }

            results.append((uid: uid as String, name: name as String, channels: inputChannels))
        }
        return results
    }

    // MARK: - Private

    /// Set the input device on an AVAudioEngine by CoreAudio UID.
    private static func setInputDevice(uid: String, on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        var deviceID = AudioDeviceID(0)

        // Find device by UID using AudioValueTranslation
        var cfUID: CFString = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { devPtr in
                var translation = AudioValueTranslation(
                    mInputData: uidPtr,
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: devPtr,
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address, 0, nil,
                    &translationSize, &translation
                )
            }
        }

        guard status == noErr, deviceID != 0 else {
            throw MicRecorderError.deviceNotFound(uid)
        }

        // Set the device on the audio unit
        let audioUnit = inputNode.audioUnit!
        var mutableDeviceID = deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setStatus == noErr else {
            throw MicRecorderError.deviceSetFailed(uid, setStatus)
        }
        logger.info("Input device set to: \(uid)")
    }
}

enum MicRecorderError: LocalizedError {
    case formatCreationFailed
    case deviceNotFound(String)
    case deviceSetFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Failed to create audio format"
        case .deviceNotFound(let uid): return "Audio device not found: \(uid)"
        case .deviceSetFailed(let uid, let status): return "Failed to set device \(uid): OSStatus \(status)"
        }
    }
}
