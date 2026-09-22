import AudioTapLib
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os.log

private let assetFallbackLogger = Logger(subsystem: AppPaths.logSubsystem, category: "AudioMixer")

/// Tier 2 of `AudioMixer.loadAudioAsFloat32`, split out of `AudioMixer.swift`
/// to keep that file under the `file_length` limit. The reader configuration
/// carries enough measured rationale that it reads better on its own anyway.
extension AudioMixer {
    /// Decode the first audio track of a file through `AVAssetReader` as mono
    /// Float32 at `AudioConstants.targetSampleRate`.
    ///
    /// The rescue path behind `AVAudioFile` in `loadAudioAsFloat32`. The reader
    /// is configured like `streamResampleFile`, and each option below carries
    /// the measurement that put it there.
    static func loadAudioFromAVAsset(url: URL) async throws -> (samples: [Float], sampleRate: Int) {
        // Precise timing is load-bearing here, not a nicety. Without it a
        // Vorbis-in-Ogg track stops yielding sample buffers after a handful and
        // `copyNextSampleBuffer()` never returns: a 49.8 s stereo Vorbis file
        // was still blocked after 280 s, and decodes in 0.20 s with the option
        // set. Nothing in this chain or in `PipelineQueue` bounds a decode and
        // cancellation cannot interrupt one, so a hang here also costs the
        // ffmpeg rescue that would otherwise follow.
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true],
        )
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw AudioMixerError.noAudioTrack
        }

        let channelCount = try await sourceChannelCount(of: audioTrack, url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                // Explicit, because the reader otherwise inherits the source's
                // byte order: an AIFF or big-endian CAF then arrives
                // byte-swapped and is read as native floats. A clean 0.5 sine
                // came back with NaN samples and a peak of 3.4e38, and nothing
                // reports an error.
                AVLinearPCMIsBigEndianKey: false,
                // Not 1: the reader's own mono fold is power-preserving, about
                // 0.707 per channel, which is +3.01 dB against the equal-weight
                // average tier 1 applies, and it emits digital silence with
                // `status == .completed` for a
                // `kAudioChannelLayoutTag_DiscreteInOrder` source. Fold in
                // Swift instead, below.
                AVNumberOfChannelsKey: channelCount,
                AVSampleRateKey: AudioConstants.targetSampleRate,
            ],
        )
        // `add` on a non-addable output raises an Objective-C exception rather
        // than failing, and asking for a variable channel count is exactly when
        // that becomes reachable. A thrown error falls through to ffmpeg.
        guard reader.canAdd(output) else {
            throw AudioMixerError.audioExtractionFailed("Cannot add audio output")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw AudioMixerError.audioExtractionFailed(
                reader.error?.localizedDescription ?? "Unknown error",
            )
        }

        // Pre-allocate based on asset duration to avoid repeated array reallocations
        var samples = [Float]()
        let duration = try await asset.load(.duration)
        let estimatedSamples = Int(CMTimeGetSeconds(duration) * Double(AudioConstants.targetSampleRate))
        if estimatedSamples > 0 {
            samples.reserveCapacity(estimatedSamples)
        }
        try drainMonoSamples(from: output, channelCount: channelCount, into: &samples)

        if reader.status == .failed {
            throw AudioMixerError.audioExtractionFailed(
                reader.error?.localizedDescription ?? "Unknown error",
            )
        }

        assetFallbackLogger
            .info(
                "AVAsset audio extracted: \(samples.count) samples at \(AudioConstants.targetSampleRate)Hz, channels=\(channelCount)",
            )
        return (samples, AudioConstants.targetSampleRate)
    }

    /// The channel count comes from the format description because
    /// `AVAudioFile`, which supplies it to `streamResampleFile`, is what has
    /// just failed by the time this tier runs.
    private static func sourceChannelCount(of track: AVAssetTrack, url: URL) async throws -> Int {
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let channels = formatDescriptions.first
            .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }),
            channels > 0
        else {
            assetFallbackLogger
                .info(
                    "AVAsset track for \(url.lastPathComponent, privacy: .private) reports no channel count, assuming mono",
                )
            return 1
        }
        return Int(channels)
    }

    /// Drain the reader, averaging each frame's channels down to one sample.
    private static func drainMonoSamples(
        from output: AVAssetReaderTrackOutput,
        channelCount: Int,
        into samples: inout [Float],
    ) throws {
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let frameCount = byteCount / (MemoryLayout<Float>.size * channelCount)
            guard frameCount > 0 else { continue }

            let sampleCount = frameCount * channelCount
            var interleaved = [Float](repeating: 0, count: sampleCount)
            let copyStatus = interleaved.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: sampleCount * MemoryLayout<Float>.size,
                    destination: destination,
                )
            }
            // Previously discarded. A failed copy left the appended frames as
            // the zeroes they were initialised to, which is silence reported as
            // success.
            guard copyStatus == kCMBlockBufferNoErr else {
                throw AudioMixerError.audioExtractionFailed("Cannot copy decoded audio (\(copyStatus))")
            }

            // Shared with the capture-time resampler so the averaging law lives
            // once; it passes mono through untouched.
            samples.append(contentsOf: AudioTapLib.downmixToMono(interleaved, channels: channelCount))
        }
    }
}
