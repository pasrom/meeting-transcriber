import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "AudioMixer")

/// Audio mixing, echo suppression, mute masking, and resampling utilities.
enum AudioMixer {
    // MARK: - Mix

    /// Mix app and mic audio tracks into a single mono M4A.
    ///
    /// Applies echo suppression, delay alignment, then averages the two tracks.
    /// Resamples to `targetRate` (default 16kHz) before saving as AAC.
    static func mix(
        appAudioPath: URL,
        micAudioPath: URL,
        outputPath: URL,
        micDelay: TimeInterval = 0,
        sampleRate: Int = 48000,
        targetRate: Int = 16000,
    ) throws {
        var appSamples = try loadAudioFileAsFloat32(url: appAudioPath)
        var micSamples = try loadAudioFileAsFloat32(url: micAudioPath)

        // Apply echo suppression
        if !appSamples.isEmpty && !micSamples.isEmpty {
            suppressEcho(
                appSamples: appSamples,
                micSamples: &micSamples,
                sampleRate: sampleRate,
                micDelay: micDelay,
            )
        }

        // Align by mic delay (shift mic samples)
        if micDelay > 0 {
            let delaySamples = Int(micDelay * Double(sampleRate))
            if delaySamples > 0 && delaySamples < micSamples.count {
                // Mic started later: prepend zeros
                micSamples = [Float](repeating: 0, count: delaySamples) + micSamples
            }
        } else if micDelay < 0 {
            let delaySamples = Int(-micDelay * Double(sampleRate))
            if delaySamples > 0 && delaySamples < appSamples.count {
                // App started later: prepend zeros to app
                appSamples = [Float](repeating: 0, count: delaySamples) + appSamples
            }
        }

        // Average the two tracks
        var mixed = mixTracks(appSamples, micSamples)

        // Resample to target rate before saving
        if sampleRate != targetRate {
            mixed = resample(mixed, from: sampleRate, to: targetRate)
        }

        try saveM4A(samples: mixed, sampleRate: targetRate, url: outputPath)
        logger.info("Mixed audio saved: \(outputPath.lastPathComponent)")
    }

    /// Average two audio tracks. If lengths differ, extend with the longer track's tail.
    static func mixTracks(_ a: [Float], _ b: [Float]) -> [Float] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }

        let minLen = min(a.count, b.count)
        var result = [Float](repeating: 0, count: max(a.count, b.count))

        // Average overlapping region
        for i in 0 ..< minLen {
            result[i] = (a[i] + b[i]) / 2
        }

        // Append tail of longer track
        if a.count > minLen {
            for i in minLen ..< a.count {
                result[i] = a[i]
            }
        } else if b.count > minLen {
            for i in minLen ..< b.count {
                result[i] = b[i]
            }
        }

        return result
    }

    // MARK: - Echo Suppression

    /// RMS-based echo suppression: gate mic where app has energy.
    ///
    /// Uses 20ms analysis windows with asymmetric margins:
    /// - 2 windows before (40ms lookahead)
    /// - 10 windows after (200ms decay)
    static func suppressEcho(
        appSamples: [Float],
        micSamples: inout [Float],
        sampleRate: Int,
        micDelay: TimeInterval = 0,
        threshold: Float = 0.01,
    ) {
        let windowSize = sampleRate / 50 // 20ms windows
        guard windowSize > 0 else { return }

        let marginBefore = 2 // 40ms
        let marginAfter = 10 // 200ms

        // Compute RMS energy per window for app audio
        let appWindowCount = appSamples.count / windowSize
        guard appWindowCount > 0 else { return }

        var appRMS = [Float](repeating: 0, count: appWindowCount)
        for i in 0 ..< appWindowCount {
            let start = i * windowSize
            let end = min(start + windowSize, appSamples.count)
            var sumSq: Float = 0
            for j in start ..< end {
                sumSq += appSamples[j] * appSamples[j]
            }
            appRMS[i] = sqrt(sumSq / Float(end - start))
        }

        // Build gate mask: true = suppress
        var gateMask = [Bool](repeating: false, count: appWindowCount)
        for i in 0 ..< appWindowCount where appRMS[i] > threshold {
            let lo = max(0, i - marginBefore)
            let hi = min(appWindowCount - 1, i + marginAfter)
            for j in lo ... hi {
                gateMask[j] = true
            }
        }

        // Apply delay offset
        let delaySamples = Int(micDelay * Double(sampleRate))
        let delayWindows = delaySamples / windowSize

        // Apply gate mask to mic samples
        let micWindowCount = micSamples.count / windowSize
        for i in 0 ..< micWindowCount {
            let appIdx = i + delayWindows
            if appIdx >= 0 && appIdx < appWindowCount && gateMask[appIdx] {
                let start = i * windowSize
                let end = min(start + windowSize, micSamples.count)
                for j in start ..< end {
                    micSamples[j] = 0 // full suppression
                }
            }
        }
    }

    // MARK: - Resampling

    /// Resample audio using AVAudioConverter (proper anti-aliasing filter).
    static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard sourceRate != targetRate, !samples.isEmpty else { return samples }

        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sourceRate), channels: 1, interleaved: false,
        ), let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(targetRate), channels: 1, interleaved: false,
        ), let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            logger.warning("AVAudioConverter init failed, falling back to linear interpolation")
            return resampleLinear(samples, from: sourceRate, to: targetRate)
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            return resampleLinear(samples, from: sourceRate, to: targetRate)
        }
        srcBuffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { ptr in
            // swiftlint:disable:next force_unwrapping
            srcBuffer.floatChannelData![0].initialize(from: ptr.baseAddress!, count: samples.count)
        }

        let outputCount = AVAudioFrameCount(Double(samples.count) * Double(targetRate) / Double(sourceRate))
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputCount) else {
            return resampleLinear(samples, from: sourceRate, to: targetRate)
        }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if let error {
            logger.warning("AVAudioConverter failed: \(error.localizedDescription), falling back")
            return resampleLinear(samples, from: sourceRate, to: targetRate)
        }

        // swiftlint:disable:next force_unwrapping
        return Array(UnsafeBufferPointer(start: dstBuffer.floatChannelData![0], count: Int(dstBuffer.frameLength)))
    }

    /// Linear interpolation fallback (no anti-aliasing).
    private static func resampleLinear(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        let ratio = Double(targetRate) / Double(sourceRate)
        let outputCount = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0 ..< outputCount {
            let srcIdx = Double(i) / ratio
            let lo = Int(srcIdx)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(srcIdx - Double(lo))
            output[i] = samples[lo] * (1 - frac) + samples[hi] * frac
        }
        return output
    }

    // MARK: - Convenience

    /// Load any audio or video file as mono Float32 samples.
    ///
    /// Uses a 3-tier fallback: AVAudioFile → AVAsset → ffmpeg CLI.
    /// Known ffmpeg-only formats (MKV, WebM, OGG) skip Apple frameworks entirely.
    static func loadAudioAsFloat32(url: URL) async throws -> (samples: [Float], sampleRate: Int) {
        // Short-circuit: known ffmpeg-only formats skip AVAudioFile + AVAsset
        if FFmpegHelper.ffmpegOnlyExtensions.contains(url.pathExtension.lowercased()) {
            return try await FFmpegHelper.loadAudioWithFFmpeg(url: url)
        }

        // Fast path: AVAudioFile handles all common audio formats
        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = Int(file.processingFormat.sampleRate)
            let samples = try readSamplesFromAudioFile(file)
            return (samples, sampleRate)
        } catch let audioFileError {
            // Fallback 1: AVAsset for video containers (MP4, MOV)
            logger.info("AVAudioFile failed for \(url.lastPathComponent): \(audioFileError.localizedDescription), trying AVAsset fallback")
            do {
                return try await loadAudioFromAVAsset(url: url)
            } catch {
                // Fallback 2: ffmpeg for unsupported formats
                logger.info("AVAsset failed for \(url.lastPathComponent): \(error.localizedDescription), trying ffmpeg fallback")
                return try await FFmpegHelper.loadAudioWithFFmpeg(url: url)
            }
        }
    }

    /// Extract audio from a video container using AVAsset.
    static func loadAudioFromAVAsset(url: URL) async throws -> (samples: [Float], sampleRate: Int) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw AudioMixerError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16000,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else {
            throw AudioMixerError.audioExtractionFailed(
                reader.error?.localizedDescription ?? "Unknown error",
            )
        }

        // Pre-allocate based on asset duration to avoid repeated array reallocations
        var samples = [Float]()
        let duration = try await asset.load(.duration)
        let estimatedSamples = Int(CMTimeGetSeconds(duration) * 16000)
        if estimatedSamples > 0 {
            samples.reserveCapacity(estimatedSamples)
        }
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = length / MemoryLayout<Float>.size
            let offset = samples.count
            samples.append(contentsOf: repeatElement(Float(0), count: floatCount))
            _ = samples.withUnsafeMutableBufferPointer { buf in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    // swiftlint:disable:next force_unwrapping
                    destination: buf.baseAddress! + offset,
                )
            }
        }

        if reader.status == .failed {
            throw AudioMixerError.audioExtractionFailed(
                reader.error?.localizedDescription ?? "Unknown error",
            )
        }

        logger.info("AVAsset audio extracted: \(samples.count) samples at 16kHz")
        return (samples, 16000)
    }

    /// Load an audio or video file, resample to a target rate, and save to a new WAV file.
    static func resampleFile(from source: URL, to destination: URL, targetRate: Int = 16000) async throws {
        let (samples, sourceRate) = try await loadAudioAsFloat32(url: source)
        let resampled = resample(samples, from: sourceRate, to: targetRate)
        try saveWAV(samples: resampled, sampleRate: targetRate, url: destination)
    }

    // MARK: - Audio I/O

    /// Load an audio file as mono Float32 samples.
    /// Supports all formats readable by AVAudioFile: WAV, MP3, M4A, AIFF, FLAC, CAF.
    static func loadAudioFileAsFloat32(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        return try readSamplesFromAudioFile(file)
    }

    /// Read mono Float32 samples from an already-opened AVAudioFile.
    private static func readSamplesFromAudioFile(_ file: AVAudioFile) throws -> [Float] {
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioMixerError.bufferCreationFailed
        }
        try file.read(into: buffer)

        guard let floatData = buffer.floatChannelData else {
            throw AudioMixerError.noFloatData
        }

        let channelCount = Int(format.channelCount)
        let sampleCount = Int(buffer.frameLength)

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: floatData[0], count: sampleCount))
        }

        // Stereo → mono (average channels)
        var mono = [Float](repeating: 0, count: sampleCount)
        for ch in 0 ..< channelCount {
            let channelPtr = floatData[ch]
            for i in 0 ..< sampleCount {
                mono[i] += channelPtr[i]
            }
        }
        let scale = 1.0 / Float(channelCount)
        for i in 0 ..< sampleCount {
            mono[i] *= scale
        }
        return mono
    }

    /// Save Float32 mono samples to a 16-bit PCM WAV file.
    static func saveWAV(samples: [Float], sampleRate: Int, url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false,
        ) else {
            throw AudioMixerError.formatCreationFailed
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioMixerError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // swiftlint:disable:next force_unwrapping
        let dst = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { src in
            dst.initialize(from: src.baseAddress!, count: samples.count) // swiftlint:disable:this force_unwrapping
        }

        try file.write(from: buffer)
    }

    /// Save Float32 mono samples to an AAC M4A file.
    static func saveM4A(samples: [Float], sampleRate: Int, url: URL, bitRate: Int = 64000) throws {
        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false,
        ) else {
            throw AudioMixerError.formatCreationFailed
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false,
        )

        // Write in chunks to avoid memory issues with large recordings
        let chunkSize = 16384
        var offset = 0
        while offset < samples.count {
            let remaining = samples.count - offset
            let count = min(chunkSize, remaining)

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: AVAudioFrameCount(count),
            ) else {
                throw AudioMixerError.bufferCreationFailed
            }
            buffer.frameLength = AVAudioFrameCount(count)

            // swiftlint:disable:next force_unwrapping
            let dst = buffer.floatChannelData![0]
            samples.withUnsafeBufferPointer { src in
                dst.initialize(from: src.baseAddress! + offset, count: count) // swiftlint:disable:this force_unwrapping
            }

            try file.write(from: buffer)
            offset += count
        }
    }
}

enum AudioMixerError: LocalizedError {
    case bufferCreationFailed
    case noFloatData
    case formatCreationFailed
    case noAudioTrack
    case audioExtractionFailed(String)
    case ffmpegNotAvailable
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed: "Failed to create audio buffer"
        case .noFloatData: "Audio buffer has no float data"
        case .formatCreationFailed: "Failed to create audio format"
        case .noAudioTrack: "File contains no audio track"
        case let .audioExtractionFailed(detail): "Audio extraction failed: \(detail)"
        case .ffmpegNotAvailable: "ffmpeg not found. Install: brew install ffmpeg"
        case let .ffmpegFailed(detail): "ffmpeg failed: \(detail)"
        }
    }
}
