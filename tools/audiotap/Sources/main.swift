import AVFoundation
import CoreAudio
import Foundation

// MARK: - Helpers

/// Convert mach_absolute_time() ticks to seconds.
private func machTicksToSeconds(_ ticks: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let nanos = Double(ticks) * Double(info.numer) / Double(info.denom)
    return nanos / 1_000_000_000.0
}

/// Write all bytes to stdout using POSIX write() — no Data copy, no Foundation overhead.
func writeAllToStdout(_ ptr: UnsafeRawPointer, count: Int) {
    var remaining = count
    var offset = 0
    while remaining > 0 {
        let written = write(STDOUT_FILENO, ptr + offset, remaining)
        if written < 0 {
            if errno == EINTR { continue }
            break
        }
        if written == 0 { break }
        remaining -= written
        offset += written
    }
}

/// Get the UID of the current default output device.
func getDefaultOutputDeviceUID() -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

    var uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let uidStatus = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
    guard uidStatus == noErr, let cfUID = uid?.takeRetainedValue() else { return nil }
    return cfUID as String
}

// MARK: - Mic Capture Handler

/// Records microphone audio to a WAV file via AVAudioEngine.
/// Monitors for default input device changes (e.g. AirPods connected) via
/// CoreAudio property listener and automatically restarts the engine.
class MicCaptureHandler {
    private var engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private let outputPath: String
    private var isRecording = false
    private var listenerInstalled = false
    var firstFrameTime: UInt64 = 0

    /// CoreAudio property address for default input device changes.
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(outputPath: String) {
        self.outputPath = outputPath
    }

    private static func deviceIDForUID(_ uid: String) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID: Unmanaged<CFString>? = Unmanaged.passUnretained(uid as CFString)
        let qualifierSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, qualifierSize, &cfUID,
            &size, &deviceID)
        return deviceID
    }

    func start(deviceUID: String? = nil) throws {
        try startEngine(deviceUID: deviceUID)
        installDeviceChangeListener()
    }

    private func startEngine(deviceUID: String? = nil) throws {
        let inputNode = engine.inputNode

        if let uid = deviceUID {
            var deviceID = Self.deviceIDForUID(uid)
            if deviceID != kAudioObjectUnknown {
                let audioUnit = inputNode.audioUnit!
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                fputs("Mic device set: \(uid) (ID \(deviceID))\n", stderr)
            } else {
                fputs("WARNING: Unknown mic device UID '\(uid)', using default\n", stderr)
            }
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        fputs(
            "Mic hardware format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount)ch\n", stderr)

        let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: hwFormat.sampleRate, channels: 1)!
        fputs("Mic tap format: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount)ch\n", stderr)

        // Append to existing file if restarting after device change
        if outputFile == nil {
            let url = URL(fileURLWithPath: outputPath)
            let wavSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: tapFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            outputFile = try AVAudioFile(forWriting: url, settings: wavSettings)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) {
            [weak self] buffer, _ in
            guard let self = self else { return }
            if self.firstFrameTime == 0 {
                self.firstFrameTime = mach_absolute_time()
            }
            do {
                try self.outputFile?.write(from: buffer)
            } catch {
                fputs("WARNING: Mic write error: \(error)\n", stderr)
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        fputs("Mic recording started: \(outputPath)\n", stderr)
    }

    /// Listen for default input device changes via CoreAudio property listener.
    /// This fires reliably even in CLI tools (unlike NSNotification).
    private func installDeviceChangeListener() {
        guard !listenerInstalled else { return }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handleDefaultInputDeviceChanged()
        }
        if status == noErr {
            listenerInstalled = true
            fputs("Mic: listening for default input device changes\n", stderr)
        } else {
            fputs("WARNING: Failed to install device change listener (status: \(status))\n", stderr)
        }
    }

    private func handleDefaultInputDeviceChanged() {
        guard isRecording else { return }
        fputs("Mic: default input device changed, restarting engine...\n", stderr)

        // Stop current engine
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        // Create a fresh engine (AVAudioEngine can be in a bad state after config change)
        engine = AVAudioEngine()

        // Restart with new system default
        do {
            try startEngine(deviceUID: nil)
            fputs("Mic: engine restarted on new default device\n", stderr)
        } catch {
            fputs("ERROR: Failed to restart mic after device change: \(error)\n", stderr)
        }
    }

    func stop() {
        isRecording = false
        if listenerInstalled {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                { _, _ in })
            listenerInstalled = false
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        outputFile = nil
        fputs("Mic recording stopped\n", stderr)
    }
}

// MARK: - CATapDescription Audio Capture

/// Captures app audio via CATapDescription (macOS 14.2+, CoreAudio).
/// No Screen Recording permission needed — only Audio Capture.
@available(macOS 14.2, *)
class AppAudioCapture {
    private let pid: pid_t
    private let sampleRate: Int
    private let channels: Int
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false
    private let writeQueue = DispatchQueue(
        label: "audiotap.writer", qos: .userInteractive)

    /// mach_absolute_time() of first audio callback
    var appFirstFrameTime: UInt64 = 0
    private var didLogFormat = false

    init(pid: pid_t, sampleRate: Int = 48000, channels: Int = 2) {
        self.pid = pid
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Translate PID to CoreAudio process AudioObjectID.
    private func translatePID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var mutablePid = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &mutablePid, &size, &objectID)
        guard status == noErr, objectID != kAudioObjectUnknown else {
            throw NSError(
                domain: "audiotap", code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to translate PID \(pid) to audio object (status: \(status))"
                ])
        }
        return objectID
    }

    func start() throws {
        let processObjectID = try translatePID()
        fputs("Process audio object ID: \(processObjectID)\n", stderr)

        // Get default output device UID
        guard let systemOutputUID = getDefaultOutputDeviceUID() else {
            throw NSError(
                domain: "audiotap", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot get default output device UID"])
        }
        fputs("System output device: \(systemOutputUID)\n", stderr)

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
                        "Failed to create process tap (status: \(tapStatus))"
                ])
        }
        tapID = newTapID
        fputs("Created process tap: \(tapID)\n", stderr)

        // Create aggregate device with the tap
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "audiotap-\(pid)",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: systemOutputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: systemOutputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(
            desc as CFDictionary, &newAggregateID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw NSError(
                domain: "audiotap", code: Int(aggStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to create aggregate device (status: \(aggStatus))"
                ])
        }
        aggregateID = newAggregateID
        fputs("Created aggregate device: \(aggregateID)\n", stderr)

        // Set up IOProc to read audio data and write to stdout
        var newProcID: AudioDeviceIOProcID?
        let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, writeQueue
        ) { [weak self] _, inInputData, _, _, _ in
            guard let self = self, self.isRunning else { return }
            let abl = inInputData.pointee

            // Log format on first callback
            if !self.didLogFormat {
                self.didLogFormat = true
                self.appFirstFrameTime = mach_absolute_time()
                let frames = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
                fputs(
                    "Audio format: \(self.sampleRate) Hz, \(abl.mNumberBuffers) buffers, \(frames) frames/buffer\n",
                    stderr)
            }

            // CATapDescription delivers interleaved float32 — write directly
            guard let data = abl.mBuffers.mData else { return }
            writeAllToStdout(data, count: Int(abl.mBuffers.mDataByteSize))
        }

        guard ioProcStatus == noErr, let validProcID = newProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw NSError(
                domain: "audiotap", code: Int(ioProcStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to create IOProc (status: \(ioProcStatus))"
                ])
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
                        "Failed to start audio device (status: \(startStatus))"
                ])
        }

        isRunning = true
        fputs("Audio capture started (CATapDescription, PID \(pid))\n", stderr)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let procID = procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }

        fputs("Audio capture stopped\n", stderr)
    }
}

// MARK: - Main Entry Point

@main
struct AudioTap {
    static func main() {
        // Disable C stdout buffering
        setbuf(stdout, nil)

        let arguments = CommandLine.arguments

        guard arguments.count >= 2 else {
            fputs(
                """
                Usage: audiotap <pid> [sample_rate] [channels] [--mic <wav_path>] [--mic-device <uid>]

                Arguments:
                  pid                 - Process ID of the app to capture audio from
                  sample_rate         - Audio sample rate in Hz (default: 48000)
                  channels            - Number of audio channels (default: 2)
                  --mic <path>        - Also record microphone to WAV file
                  --mic-device <uid>  - CoreAudio device UID for mic

                Example:
                  audiotap 12345 48000 2 > output.pcm
                  audiotap 12345 48000 2 --mic /tmp/mic.wav > output.pcm

                Output:
                  Raw PCM audio data is written to stdout (interleaved float32)
                  Progress/errors are written to stderr

                Required:
                  macOS 14.2+ (for CATapDescription)
                  No Screen Recording permission needed for audio capture

                """, stderr)
            exit(1)
        }

        // Parse args
        var positionalArgs: [String] = []
        var micPath: String?
        var micDeviceUID: String?
        var i = 1
        while i < arguments.count {
            if arguments[i] == "--mic" {
                if i + 1 < arguments.count {
                    micPath = arguments[i + 1]
                    i += 2
                } else {
                    fputs("ERROR: --mic requires a file path argument\n", stderr)
                    exit(1)
                }
            } else if arguments[i] == "--mic-device" {
                if i + 1 < arguments.count {
                    micDeviceUID = arguments[i + 1]
                    i += 2
                } else {
                    fputs("ERROR: --mic-device requires a device UID argument\n", stderr)
                    exit(1)
                }
            } else {
                positionalArgs.append(arguments[i])
                i += 1
            }
        }

        guard !positionalArgs.isEmpty, let pid = Int32(positionalArgs[0]) else {
            fputs("ERROR: valid PID is required as first argument\n", stderr)
            exit(1)
        }

        let sampleRate = positionalArgs.count > 1 ? Int(positionalArgs[1]) ?? 48000 : 48000
        let channels = positionalArgs.count > 2 ? Int(positionalArgs[2]) ?? 2 : 2

        fputs("=== AudioTap (CATapDescription) ===\n", stderr)
        fputs("Target PID: \(pid)\n", stderr)
        fputs("Sample Rate: \(sampleRate) Hz\n", stderr)
        fputs("Channels: \(channels)\n", stderr)
        if let micPath = micPath {
            fputs("Mic output: \(micPath)\n", stderr)
        }
        if let micDeviceUID = micDeviceUID {
            fputs("Mic device UID: \(micDeviceUID)\n", stderr)
        }
        fputs("\n", stderr)

        guard #available(macOS 14.2, *) else {
            fputs("ERROR: macOS 14.2+ required for CATapDescription\n", stderr)
            exit(1)
        }

        // Create capture handler
        let handler = AppAudioCapture(pid: pid, sampleRate: sampleRate, channels: channels)

        // Create mic handler if requested
        var micHandler: MicCaptureHandler?
        if let micPath = micPath {
            micHandler = MicCaptureHandler(outputPath: micPath)
        }

        do {
            try handler.start()

            // Start mic capture after app capture
            if let mic = micHandler {
                do {
                    try mic.start(deviceUID: micDeviceUID)
                } catch {
                    fputs("ERROR: Failed to start mic capture: \(error)\n", stderr)
                    fputs("Continuing with app audio only.\n", stderr)
                    micHandler = nil
                }
            }
        } catch {
            fputs("FATAL ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        // Set up SIGTERM handler for clean shutdown
        let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)

        sigSource.setEventHandler {
            fputs("\nReceived SIGTERM, stopping...\n", stderr)

            handler.stop()
            micHandler?.stop()

            if let mic = micHandler {
                let appTime = handler.appFirstFrameTime
                let micTime = mic.firstFrameTime
                if appTime > 0 && micTime > 0 {
                    let delaySec = machTicksToSeconds(micTime) - machTicksToSeconds(appTime)
                    fputs(String(format: "MIC_DELAY=%+.6f\n", delaySec), stderr)
                } else {
                    fputs("MIC_DELAY=+0.000000\n", stderr)
                }
            }

            fputs("Exiting cleanly\n", stderr)
            exit(0)
        }
        sigSource.resume()

        // Run forever — SIGTERM handler calls exit(0)
        dispatchMain()
    }
}
