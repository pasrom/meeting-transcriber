import CoreMedia
import Foundation
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "SCKAudioCapture")

/// System-audio capture via ScreenCaptureKit (`SCStream` with `capturesAudio`).
///
/// Unlike the CoreAudio process tap (`AppAudioCapture`), ScreenCaptureKit taps
/// the system audio mix at a stage that *includes* conferencing apps which
/// render their call audio through non-standard pipelines — Microsoft Teams and
/// Zoom in particular, whose downlink is zero-filled when read through a process
/// tap. This is the default app-audio backend for that reason.
///
/// Captures everything you can hear except this process's own audio
/// (`excludesCurrentProcessAudio`), matching the previous global-tap behaviour
/// so single-app meetings are captured cleanly. Output is interleaved float32
/// PCM written to `outputFileDescriptor`, identical in layout to the process-tap
/// backend so the downstream mix/resample pipeline is unchanged.
@available(macOS 14.2, *)
public final class SCKAudioCapture: NSObject {
    private let sampleRate: Int
    private let channels: Int
    private let outputFileDescriptor: Int32
    private let debugLogging: Bool

    private var stream: SCStream?
    private var isRunning = false

    /// Serial queue that both receives SCStream sample buffers and performs the
    /// blocking file writes, so buffer handling never races and the
    /// `interleaveScratch` reuse below is single-threaded.
    private let writeQueue = DispatchQueue(label: "audiotap.sck.writer", qos: .userInteractive)

    private var debugRMS = DebugRMSReporter()
    private var debugTotalBytes: UInt64 = 0
    private let levelPublisher = LevelPublisher()

    /// Reused interleave buffer for the non-interleaved (planar) SCK path.
    /// writeQueue-confined — never touch from another thread.
    private var interleaveScratch = [Float]()

    public private(set) var appFirstFrameTime: UInt64 = 0
    public private(set) var actualSampleRate: Int = 0
    public private(set) var actualChannels: Int = 0
    private var didLogFormat = false

    public var currentLevelDBFS: Double {
        levelPublisher.currentLevelDBFS
    }

    /// - Parameters:
    ///   - outputFileDescriptor: File descriptor to write raw interleaved
    ///     float32 PCM to.
    ///   - sampleRate: Requested capture sample rate (default 48000).
    ///   - channels: Requested channel count (default 2).
    ///   - debugLogging: Emit periodic RMS-energy log lines.
    public init(
        outputFileDescriptor: Int32,
        sampleRate: Int = 48000,
        channels: Int = 2,
        debugLogging: Bool = false,
    ) {
        self.outputFileDescriptor = outputFileDescriptor
        self.sampleRate = sampleRate
        self.channels = channels
        self.debugLogging = debugLogging
        super.init()
    }

    public func start() throws {
        let content = try fetchShareableContent()
        guard let display = content.displays.first else {
            throw NSError(
                domain: "audiotap.sck", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "No display available for ScreenCaptureKit audio capture"],
            )
        }

        // Audio-only intent, but SCK requires a content filter rooted at a
        // display and (on some macOS versions) only pumps audio while a video
        // stream is also running. A 2×2 @ 1 fps video config keeps that path
        // alive at negligible cost; the frames are received and discarded.
        let filter = SCContentFilter(
            display: display, excludingApplications: [], exceptingWindows: [],
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = sampleRate
        config.channelCount = channels
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
        // Consume the throwaway video stream too; see the 2×2 note above.
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writeQueue)

        isRunning = true
        do {
            try startStream(newStream)
        } catch {
            isRunning = false
            throw error
        }
        stream = newStream

        // Authoritative format is read from the first delivered buffer; seed
        // with the requested values so callers have something before then.
        actualSampleRate = sampleRate
        actualChannels = channels

        if debugLogging {
            logger.info(
                "[debug] SCK audio capture started on display \(display.displayID, privacy: .public) (requested \(self.sampleRate, privacy: .public) Hz, \(self.channels, privacy: .public)ch)",
            )
        }
        logger.info("SCK audio capture started (rate: \(self.sampleRate) Hz, \(self.channels)ch)")
    }

    public func stop() {
        isRunning = false
        if let stream {
            let sem = DispatchSemaphore(value: 0)
            stream.stopCapture { error in
                if let error {
                    logger.warning("SCK stopCapture error: \(error.localizedDescription, privacy: .public)")
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 5)
            self.stream = nil
        }
        // Drain pending buffer-handling/writes before the caller closes the fd —
        // a late buffer must not write to a recycled descriptor.
        writeQueue.sync {}
        didLogFormat = false
        if debugLogging {
            logger.info("[debug] SCK audio capture stopping: totalBytes=\(self.debugTotalBytes, privacy: .public)")
        }
        logger.info("SCK audio capture stopped")
    }

    // MARK: - SCK lifecycle bridging (async → sync)

    /// Fetch shareable content, blocking the caller until SCK responds. SCK's
    /// completion runs on an internal queue (never the caller's thread), so the
    /// semaphore wait can't deadlock.
    private func fetchShareableContent() throws -> SCShareableContent {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<SCShareableContent, Error> = .failure(NSError(
            domain: "audiotap.sck", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "ScreenCaptureKit content query did not complete"],
        ))
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            if let content {
                result = .success(content)
            } else if let error {
                result = .failure(error)
            }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 10) == .success else {
            throw NSError(
                domain: "audiotap.sck", code: -3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Timed out querying ScreenCaptureKit shareable content"],
            )
        }
        return try result.get()
    }

    private func startStream(_ stream: SCStream) throws {
        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        stream.startCapture { error in
            startError = error
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 10) == .success else {
            throw NSError(
                domain: "audiotap.sck", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Timed out starting ScreenCaptureKit capture"],
            )
        }
        if let startError { throw startError }
    }

    // MARK: - Audio handling

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let asbd = asbdPtr.pointee
        let channelCount = Int(asbd.mChannelsPerFrame)
        guard channelCount > 0 else { return }

        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil,
        )
        guard sizeNeeded > 0 else { return }

        let ablRaw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment,
        )
        defer { ablRaw.deallocate() }
        let ablPtr = ablRaw.assumingMemoryBound(to: AudioBufferList.self)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer,
        )
        guard status == noErr else { return }
        // blockBuffer retains the backing samples for the body of this method.
        let list = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard list.count > 0 else { return }

        if !didLogFormat {
            didLogFormat = true
            if appFirstFrameTime == 0 {
                appFirstFrameTime = mach_absolute_time()
            }
            actualChannels = channelCount
            actualSampleRate = Int(asbd.mSampleRate)
            logger.info(
                "SCK audio format: \(self.actualSampleRate) Hz, \(self.actualChannels)ch, \(list.count) buffers",
            )
        }

        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        if isNonInterleaved, channelCount > 1 {
            writeInterleaving(list: list, channelCount: channelCount)
        } else if let data = list[0].mData {
            // Already interleaved (or mono) — write straight through.
            let byteCount = Int(list[0].mDataByteSize)
            writeAllToFileHandle(outputFileDescriptor, data, count: byteCount)
            accumulate(dataPtr: data, byteCount: byteCount)
        }
    }

    /// Interleave planar (non-interleaved) SCK buffers into a single
    /// L,R,L,R… float32 stream and write it. Reuses `interleaveScratch`.
    private func writeInterleaving(list: UnsafeMutableAudioBufferListPointer, channelCount: Int) {
        let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
        guard frames > 0 else { return }
        let total = frames * channelCount
        if interleaveScratch.count < total {
            interleaveScratch = [Float](repeating: 0, count: total)
        }

        interleaveScratch.withUnsafeMutableBufferPointer { out in
            for ch in 0 ..< channelCount {
                guard let chData = list[ch].mData else { continue }
                let src = chData.assumingMemoryBound(to: Float.self)
                for i in 0 ..< frames {
                    out[i * channelCount + ch] = src[i]
                }
            }
        }

        let byteCount = total * MemoryLayout<Float>.size
        interleaveScratch.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            writeAllToFileHandle(outputFileDescriptor, base, count: byteCount)
            accumulate(dataPtr: base, byteCount: byteCount)
        }
    }

    /// Accumulate RMS energy, publish the instantaneous level, and emit the
    /// throttled debug log line. Mirrors `AppAudioCapture`'s metering so the
    /// menu-bar indicator behaves identically across backends.
    private func accumulate(dataPtr: UnsafeRawPointer, byteCount: Int) {
        let count = byteCount / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let buf = UnsafeBufferPointer(
            start: dataPtr.assumingMemoryBound(to: Float.self), count: count,
        )
        var sumSq: Double = 0
        for sample in buf {
            sumSq += Double(sample) * Double(sample)
        }
        debugRMS.add(sumSq: sumSq, samples: count)
        debugTotalBytes += UInt64(byteCount)
        levelPublisher.publish(level: debugRMS.lastLevelDBFS)

        guard let report = debugRMS.tick(), debugLogging else { return }
        let dBStr = String(format: "%.1f", report.dBFS)
        logger.info(
            "[debug] SCK app audio RMS (5s): \(dBStr, privacy: .public) dBFS, samples=\(report.samples, privacy: .public), totalBytes=\(self.debugTotalBytes, privacy: .public)",
        )
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

@available(macOS 14.2, *)
extension SCKAudioCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType,
    ) {
        guard isRunning, type == .audio else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        handleAudio(sampleBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("SCK stream stopped with error: \(error.localizedDescription, privacy: .public)")
        isRunning = false
    }
}

@available(macOS 14.2, *)
extension SCKAudioCapture: AppAudioCapturing {}
