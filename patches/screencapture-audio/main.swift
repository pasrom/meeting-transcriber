import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreAudio

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
            if errno == EINTR { continue }  // interrupted by signal — retry
            break
        }
        if written == 0 { break }  // stdout closed
        remaining -= written
        offset += written
    }
}

// MARK: - Mic Capture Handler (VoiceProcessingIO AEC)

/// Records microphone audio with Apple's VoiceProcessingIO echo cancellation.
/// VoiceProcessingIO monitors the system speaker output and subtracts it from the
/// mic input in real-time — the same AEC that FaceTime uses.
class MicCaptureHandler {
    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private let outputPath: String
    /// mach_absolute_time() of first audio buffer — for computing MIC_DELAY
    var firstFrameTime: UInt64 = 0

    init(outputPath: String) {
        self.outputPath = outputPath
    }

    func start() throws {
        let inputNode = engine.inputNode

        // Enable VoiceProcessingIO — this activates AEC + noise suppression
        try inputNode.setVoiceProcessingEnabled(true)
        fputs("Mic: VoiceProcessingIO enabled (AEC active)\n", stderr)

        // Query the format from the input node
        let tapFormat = inputNode.outputFormat(forBus: 0)
        fputs("Mic format: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount)ch\n", stderr)

        // Create output WAV file — 16-bit PCM mono at the input node's sample rate
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

        // Install tap to capture audio buffers
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, when in
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
        fputs("Mic recording started: \(outputPath)\n", stderr)
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil  // AVAudioFile finalizes WAV header on dealloc
        fputs("Mic recording stopped\n", stderr)
    }
}

// MARK: - Audio Capture Stream Handler

@available(macOS 13.0, *)
class AudioCaptureHandler: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private let bundleID: String
    private let sampleRate: Int
    private let channels: Int
    private var isRunning = false
    private let writeQueue = DispatchQueue(label: "audio.stdout.writer", qos: .userInteractive)
    // Accessed only from writeQueue (the sampleHandlerQueue) — no additional synchronization needed
    private var didLogFormat = false
    private var interleaveBuffer = [Float]()  // reusable — avoids alloc per callback
    /// mach_absolute_time() of first audio callback — for computing MIC_DELAY
    var appFirstFrameTime: UInt64 = 0

    init(bundleID: String, sampleRate: Int = 48000, channels: Int = 2) {
        self.bundleID = bundleID
        self.sampleRate = sampleRate
        self.channels = channels
        super.init()
    }

    // MARK: - Permission Check

    func checkScreenRecordingPermission() -> Bool {
        if #available(macOS 14.0, *) {
            // macOS 14.0+ has canRecordScreen property
            return CGPreflightScreenCaptureAccess()
        } else {
            // For macOS 13.x, request permission
            return CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Stream Setup

    func start() async throws {
        fputs("Checking Screen Recording permission...\n", stderr)

        guard checkScreenRecordingPermission() else {
            fputs("ERROR: Screen Recording permission not granted\n", stderr)
            fputs("Please enable: System Settings → Privacy & Security → Screen Recording\n", stderr)
            throw NSError(domain: "AudioCapture", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission required"])
        }

        fputs("Screen Recording permission: OK\n", stderr)
        fputs("Fetching available applications...\n", stderr)

        // Get all shareable content
        let availableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        // Find application by bundle ID
        guard let targetApp = availableContent.applications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else {
            fputs("ERROR: Application with bundleID '\(bundleID)' not found\n", stderr)
            fputs("\nAvailable applications:\n", stderr)
            for app in availableContent.applications.prefix(10) {
                fputs("  - \(app.applicationName) (\(app.bundleIdentifier))\n", stderr)
            }
            throw NSError(domain: "AudioCapture", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Application not found"])
        }

        fputs("Found application: \(targetApp.applicationName)\n", stderr)

        // Configure stream for audio capture only
        let configuration = SCStreamConfiguration()

        // Audio AND video capture (ScreenCaptureKit requires both for audio to work)
        configuration.capturesAudio = true

        // Video settings (minimum resolution)
        configuration.width = 100
        configuration.height = 100
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)  // 2 FPS
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        // Audio configuration
        configuration.sampleRate = self.sampleRate
        configuration.channelCount = self.channels

        // Exclude our own process audio (we don't want to capture our own sounds)
        configuration.excludesCurrentProcessAudio = true

        fputs("Stream configuration:\n", stderr)
        fputs("  - Sample Rate: \(configuration.sampleRate) Hz\n", stderr)
        fputs("  - Channels: \(configuration.channelCount)\n", stderr)
        fputs("  - Audio Only: true\n", stderr)

        // Create filter for app-specific audio
        guard let display = availableContent.displays.first else {
            fputs("ERROR: No display found\n", stderr)
            throw NSError(domain: "AudioCapture", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        // Get windows for the app
        let appWindows = availableContent.windows.filter { window in
            window.owningApplication?.bundleIdentifier == bundleID
        }

        fputs("Found \(appWindows.count) windows for app\n", stderr)

        // Create content filter for app-specific audio
        // Note: ScreenCaptureKit audio capture on macOS 15+ supports app-specific filtering
        // when using display-wide filter with specific apps included
        fputs("Creating app-specific audio filter\n", stderr)
        let audioFilter = SCContentFilter(
            display: display,
            including: [targetApp],
            exceptingWindows: []
        )

        fputs("Created audio filter for: \(targetApp.applicationName)\n", stderr)

        let newStream = SCStream(filter: audioFilter, configuration: configuration, delegate: self)
        stream = newStream

        fputs("Created SCStream instance\n", stderr)

        // Add audio output handler on dedicated serial queue to prevent concurrent writes
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)

        fputs("Added audio output handler (serial queue)\n", stderr)
        fputs("Starting audio capture stream...\n", stderr)

        do {
            try await newStream.startCapture()
            isRunning = true
            fputs("Audio capture started successfully!\n", stderr)
            fputs("Streaming PCM audio data to stdout...\n\n", stderr)
        } catch {
            fputs("ERROR: Failed to start stream: \(error)\n", stderr)
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        fputs("\nStopping audio capture...\n", stderr)
        // Synchronous stop: remove output and invalidate
        // SCStream.stopCapture is async but we need to stop from a signal handler
        // so we just mark as stopped; the process will exit shortly
        isRunning = false
        fputs("Audio capture stopped\n", stderr)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        // Only process audio samples
        guard outputType == .audio else {
            return
        }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            fputs("WARNING: No format description in sample buffer\n", stderr)
            return
        }

        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            fputs("WARNING: No AudioStreamBasicDescription\n", stderr)
            return
        }

        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        // Log format once + record first frame timestamp
        if !didLogFormat {
            didLogFormat = true
            appFirstFrameTime = mach_absolute_time()
            fputs(String(format: "Audio format: %.0f Hz, %dch, %d-bit, flags=0x%X (nonInterleaved=%@)\n",
                         asbd.mSampleRate,
                         Int(asbd.mChannelsPerFrame),
                         Int(asbd.mBitsPerChannel),
                         UInt(asbd.mFormatFlags),
                         isNonInterleaved ? "true" : "false"), stderr)
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return }

        if isNonInterleaved {
            // ── Non-interleaved (planar): separate buffer per channel ──
            // ScreenCaptureKit on macOS 13+ typically delivers planar float32:
            //   Buffer 0: [L0, L1, ..., Ln]
            //   Buffer 1: [R0, R1, ..., Rn]
            // We must interleave to [L0, R0, L1, R1, ...] for stdout.

            // Use size-query pattern: first call gets required size, second fills the list
            var sizeNeeded: Int = 0
            let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &sizeNeeded,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: nil
            )

            guard sizeStatus == noErr, sizeNeeded > 0 else {
                fputs("WARNING: Failed to query AudioBufferList size (status=\(sizeStatus))\n", stderr)
                return
            }

            let ablRaw = UnsafeMutableRawPointer.allocate(
                byteCount: sizeNeeded,
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { ablRaw.deallocate() }

            let ablPtr = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

            // blockBuffer must be retained for the lifetime of the AudioBufferList pointers
            var blockBuffer: CMBlockBuffer?
            let fillStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablPtr,
                bufferListSize: sizeNeeded,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard fillStatus == noErr else {
                fputs("WARNING: Failed to fill AudioBufferList (status=\(fillStatus))\n", stderr)
                return
            }

            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let channelCount = Int(asbd.mChannelsPerFrame)

            // Collect per-channel float pointers
            var channelPtrs: [UnsafeBufferPointer<Float>] = []
            var framesPerChannel = 0

            for i in 0..<min(channelCount, abl.count) {
                let buf = abl[i]
                let floatCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                if let data = buf.mData {
                    channelPtrs.append(UnsafeBufferPointer(
                        start: data.assumingMemoryBound(to: Float.self),
                        count: floatCount
                    ))
                    framesPerChannel = max(framesPerChannel, floatCount)
                }
            }

            guard !channelPtrs.isEmpty, framesPerChannel > 0 else { return }

            // Interleave: [L0, R0, L1, R1, ...]
            let interleavedCount = framesPerChannel * channelPtrs.count
            if interleaveBuffer.count < interleavedCount {
                interleaveBuffer = [Float](repeating: 0.0, count: interleavedCount)
            }

            for frame in 0..<framesPerChannel {
                for ch in 0..<channelPtrs.count {
                    let idx = frame * channelPtrs.count + ch
                    if frame < channelPtrs[ch].count {
                        interleaveBuffer[idx] = channelPtrs[ch][frame]
                    } else {
                        interleaveBuffer[idx] = 0.0  // zero-fill if channel is shorter
                    }
                }
            }

            // Write interleaved data to stdout via POSIX write()
            interleaveBuffer.withUnsafeBufferPointer { bufPtr in
                writeAllToStdout(bufPtr.baseAddress!, count: interleavedCount * MemoryLayout<Float>.size)
            }
        } else {
            // ── Interleaved: single buffer with [L0, R0, L1, R1, ...] ──
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                fputs("WARNING: No data buffer in sample\n", stderr)
                return
            }

            var length: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>?

            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )

            guard status == kCMBlockBufferNoErr, let data = dataPointer else {
                fputs("WARNING: Failed to get data pointer (status=\(status))\n", stderr)
                return
            }

            writeAllToStdout(data, count: length)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("ERROR: Stream stopped with error: \(error.localizedDescription)\n", stderr)
        isRunning = false
    }
}

// MARK: - Main Entry Point

@available(macOS 13.0, *)
@main
struct ScreenCaptureAudio {
    static func main() async {
        // Disable C stdout buffering so writes go to pipe immediately
        setbuf(stdout, nil)

        // Parse command line arguments
        let arguments = CommandLine.arguments

        guard arguments.count >= 2 else {
            fputs("""
            Usage: screencapture-audio <bundleID> [sample_rate] [channels] [--mic <wav_path>]

            Arguments:
              bundleID     - Application bundle identifier (e.g., com.apple.Safari)
              sample_rate  - Audio sample rate in Hz (default: 48000)
              channels     - Number of audio channels (default: 2)
              --mic <path> - Also record microphone with AEC to WAV file

            Example:
              screencapture-audio com.google.Chrome 48000 2 > output.pcm
              screencapture-audio com.google.Chrome 48000 2 --mic /tmp/mic.wav > output.pcm

            Output:
              Raw PCM audio data is written to stdout (interleaved float32)
              Progress/errors are written to stderr

            Required Permissions:
              - Screen Recording (System Settings → Privacy & Security → Screen Recording)
              - Microphone (if --mic is used)

            """, stderr)
            exit(1)
        }

        // Parse positional args and --mic flag
        var positionalArgs: [String] = []
        var micPath: String? = nil
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
            } else {
                positionalArgs.append(arguments[i])
                i += 1
            }
        }

        guard !positionalArgs.isEmpty else {
            fputs("ERROR: bundleID is required\n", stderr)
            exit(1)
        }

        let bundleID = positionalArgs[0]
        let sampleRate = positionalArgs.count > 1 ? Int(positionalArgs[1]) ?? 48000 : 48000
        let channels = positionalArgs.count > 2 ? Int(positionalArgs[2]) ?? 2 : 2

        fputs("=== ScreenCaptureKit Audio Capture ===\n", stderr)
        fputs("Target Bundle ID: \(bundleID)\n", stderr)
        fputs("Sample Rate: \(sampleRate) Hz\n", stderr)
        fputs("Channels: \(channels)\n", stderr)
        if let micPath = micPath {
            fputs("Mic output: \(micPath) (AEC enabled)\n", stderr)
        }
        fputs("\n", stderr)

        // Create capture handler
        let handler = AudioCaptureHandler(
            bundleID: bundleID,
            sampleRate: sampleRate,
            channels: channels
        )

        // Create mic handler if requested
        var micHandler: MicCaptureHandler? = nil
        if let micPath = micPath {
            micHandler = MicCaptureHandler(outputPath: micPath)
        }

        do {
            // Start app audio capture
            try await handler.start()

            // Start mic capture (after app capture so AEC reference is active)
            if let mic = micHandler {
                do {
                    try mic.start()
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
        signal(SIGTERM, SIG_IGN)  // ignore default handler, let DispatchSource handle it

        sigSource.setEventHandler {
            fputs("\nReceived SIGTERM, stopping...\n", stderr)

            // 1. Stop app audio capture
            handler.stop()

            // 2. Stop mic capture + finalize WAV
            micHandler?.stop()

            // 3. Compute and output MIC_DELAY
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

        // Run the main dispatch loop (replaces while-true sleep loop)
        dispatchMain()
    }
}
