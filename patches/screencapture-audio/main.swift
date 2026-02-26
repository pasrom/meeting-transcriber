import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreAudio

// MARK: - Helpers

/// Write all bytes to stdout using POSIX write() — no Data copy, no Foundation overhead.
func writeAllToStdout(_ ptr: UnsafeRawPointer, count: Int) {
    var remaining = count
    var offset = 0
    while remaining > 0 {
        let written = write(STDOUT_FILENO, ptr + offset, remaining)
        if written <= 0 { break }
        remaining -= written
        offset += written
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
    private let writeQueue = DispatchQueue(label: "audio.stdout.writer")
    private var didLogFormat = false
    private var interleaveBuffer = [Float]()  // reusable — avoids alloc per callback

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
            fputs("Please enable: System Settings \u{2192} Privacy & Security \u{2192} Screen Recording\n", stderr)
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

    func stop() async throws {
        guard isRunning else { return }
        fputs("\nStopping audio capture...\n", stderr)
        try await stream?.stopCapture()
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

        // Log format once
        if !didLogFormat {
            didLogFormat = true
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
            Usage: screencapture-audio <bundleID> [sample_rate] [channels]

            Arguments:
              bundleID     - Application bundle identifier (e.g., com.apple.Safari)
              sample_rate  - Audio sample rate in Hz (default: 48000)
              channels     - Number of audio channels (default: 2)

            Example:
              screencapture-audio com.google.Chrome 48000 2 > output.pcm

            Output:
              Raw PCM audio data is written to stdout (interleaved float32)
              Progress/errors are written to stderr

            Required Permissions:
              - Screen Recording (System Settings \u{2192} Privacy & Security \u{2192} Screen Recording)

            """, stderr)
            exit(1)
        }

        let bundleID = arguments[1]
        let sampleRate = arguments.count > 2 ? Int(arguments[2]) ?? 48000 : 48000
        let channels = arguments.count > 3 ? Int(arguments[3]) ?? 2 : 2

        fputs("=== ScreenCaptureKit Audio Capture ===\n", stderr)
        fputs("Target Bundle ID: \(bundleID)\n", stderr)
        fputs("Sample Rate: \(sampleRate) Hz\n", stderr)
        fputs("Channels: \(channels)\n\n", stderr)

        // Create capture handler
        let handler = AudioCaptureHandler(
            bundleID: bundleID,
            sampleRate: sampleRate,
            channels: channels
        )

        do {
            // Start capture
            try await handler.start()

            // Keep running indefinitely
            // Signal handling is delegated to parent process
            // Note: Task.sleep with very large values can be optimized away,
            // so we use a loop with reasonable intervals
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            }

        } catch is CancellationError {
            fputs("\nReceived cancellation, stopping...\n", stderr)
            try? await handler.stop()
        } catch {
            fputs("FATAL ERROR: \(error.localizedDescription)\n", stderr)
            try? await handler.stop()
            exit(1)
        }

        fputs("Exiting cleanly\n", stderr)
        exit(0)
    }
}
