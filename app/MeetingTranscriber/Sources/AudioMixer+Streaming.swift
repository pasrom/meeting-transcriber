@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os.log

private let streamingLogger = Logger(subsystem: AppPaths.logSubsystem, category: "AudioMixer")

extension AudioMixer {
    /// Decode and resample incrementally so long imports never need one buffer for
    /// the entire recording. `AVAudioPCMBuffer` stores byte capacity as `UInt32`;
    /// a four hour 48 kHz stereo recording exceeds that even though its frame count
    /// still fits in `AVAudioFrameCount`.
    static func streamResampleFile(
        from source: URL,
        to destination: URL,
        targetRate: Int,
        sourceChannelCount: AVAudioChannelCount,
    ) async throws {
        let asset = AVURLAsset(
            url: source,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true],
        )
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw AudioMixerError.noAudioTrack
        }
        guard sourceChannelCount > 0 else {
            throw AudioMixerError.formatCreationFailed
        }

        let timeRange = try await audioTrack.load(.timeRange)
        let expectedFrameCount = expectedFrameCount(for: timeRange.duration, targetRate: targetRate)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
                AVNumberOfChannelsKey: sourceChannelCount,
                AVSampleRateKey: targetRate,
            ],
        )
        guard reader.canAdd(output) else {
            throw AudioMixerError.audioExtractionFailed("Cannot add audio output")
        }
        reader.add(output)

        let (format, destinationFile) = try makeDestinationFile(at: destination, sampleRate: targetRate)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        guard reader.startReading() else {
            throw AudioMixerError.audioExtractionFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        let writtenFrameCount = try writeDecodedAudio(
            from: output,
            sourceChannelCount: Int(sourceChannelCount),
            format: format,
            to: destinationFile,
        )
        if reader.status == .failed {
            throw AudioMixerError.audioExtractionFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        try finalizeDecodedAudio(
            writtenFrameCount: writtenFrameCount,
            expectedFrameCount: expectedFrameCount,
            targetRate: targetRate,
            format: format,
            file: destinationFile,
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        completed = true
    }

    private static func expectedFrameCount(for duration: CMTime, targetRate: Int) -> Int64? {
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return Int64((durationSeconds * Double(targetRate)).rounded())
    }

    private static func finalizeDecodedAudio(
        writtenFrameCount: Int64,
        expectedFrameCount: Int64?,
        targetRate: Int,
        format: AVAudioFormat,
        file: AVAudioFile,
    ) throws {
        guard let expectedFrameCount else { return }

        streamingLogger.info(
            "Streaming resample wrote \(writtenFrameCount, privacy: .public) of \(expectedFrameCount, privacy: .public) expected frames",
        )
        let shortfall = expectedFrameCount - writtenFrameCount
        // Allow 10 ms for duration rounding and normal decoder drift.
        let shortfallTolerance = Int64(max(targetRate / 100, 1))
        guard shortfall <= shortfallTolerance else {
            throw AudioMixerError.audioExtractionFailed(
                "decoded \(writtenFrameCount) of \(expectedFrameCount) frames",
            )
        }
        if shortfall > 0 {
            try appendSilence(frameCount: shortfall, format: format, to: file)
        }
    }

    private static func makeDestinationFile(at url: URL, sampleRate: Int) throws -> (AVAudioFormat, AVAudioFile) {
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
        return (format, file)
    }

    private static func writeDecodedAudio(
        from output: AVAssetReaderTrackOutput,
        sourceChannelCount: Int,
        format: AVAudioFormat,
        to file: AVAudioFile,
    ) throws -> Int64 {
        var writtenFrameCount: Int64 = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let bytesPerFrame = MemoryLayout<Float>.size * sourceChannelCount
            let frameCount = byteCount / bytesPerFrame
            guard frameCount > 0 else { continue }
            guard frameCount <= Int(UInt32.max),
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: format,
                      frameCapacity: AVAudioFrameCount(frameCount),
                  ) else {
                throw AudioMixerError.bufferCreationFailed
            }

            let sampleCount = frameCount * sourceChannelCount
            var interleavedSamples = [Float](repeating: 0, count: sampleCount)
            let copyStatus = interleavedSamples.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: sampleCount * MemoryLayout<Float>.size,
                    destination: destination,
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw AudioMixerError.audioExtractionFailed("Cannot copy decoded audio (\(copyStatus))")
            }

            // swiftlint:disable:next force_unwrapping
            let monoSamples = buffer.floatChannelData![0]
            let scale = 1.0 / Float(sourceChannelCount)
            for frame in 0 ..< frameCount {
                let firstSample = frame * sourceChannelCount
                var sum: Float = 0
                for channel in 0 ..< sourceChannelCount {
                    sum += interleavedSamples[firstSample + channel]
                }
                monoSamples[frame] = sum * scale
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            try file.write(from: buffer)
            writtenFrameCount += Int64(frameCount)
        }
        return writtenFrameCount
    }

    private static func appendSilence(
        frameCount: Int64,
        format: AVAudioFormat,
        to file: AVAudioFile,
    ) throws {
        var remainingFrameCount = frameCount
        let chunkCapacity = 65536
        while remainingFrameCount > 0 {
            let chunkFrameCount = min(Int64(chunkCapacity), remainingFrameCount)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunkFrameCount),
            ) else {
                throw AudioMixerError.bufferCreationFailed
            }
            // swiftlint:disable:next force_unwrapping
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(chunkFrameCount))
            buffer.frameLength = AVAudioFrameCount(chunkFrameCount)
            try file.write(from: buffer)
            remainingFrameCount -= chunkFrameCount
        }
    }
}
