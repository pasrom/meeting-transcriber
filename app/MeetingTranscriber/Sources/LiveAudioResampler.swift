import AudioTapLib

// `@preconcurrency`: AVAudioPCMBuffer + AVAudioConverter lack Sendable
// annotations — same gap AudioMixer.swift / DualSourceRecorder.swift work
// around for the batch path.
@preconcurrency import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveAudioResampler")

/// Streams audio buffers from a `LiveAudioSink` through an `AVAudioConverter`
/// to produce 16 kHz mono Float32 buffers suitable for `StreamingTranscriber`.
///
/// Input format (channel count + sample rate) is locked on the first buffer
/// and the converter is created lazily — subsequent buffers reuse it so
/// internal resampling state persists across chunks (no boundary clicks).
/// A format change mid-session rebuilds the converter and logs a warning.
///
/// Used by `LiveTranscriptionController`'s app-channel feed. App buffers
/// normally arrive already capture-time resampled to 16 kHz mono (via
/// `AppAudioCapture`'s `StreamingMonoResampler`) and short-circuit through
/// unchanged; real conversion only happens on the resampler-nil fallback
/// path, where raw device-rate buffers (e.g. 48 kHz interleaved stereo)
/// come through. The mic sink runs through `MicCaptureHandler`'s own
/// converter and bypasses this resampler entirely.
final class LiveAudioResampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var driftDetector = SampleRateDriftDetector()

    static let targetSampleRate: Double = 16000
    static let targetChannels: AVAudioChannelCount = 1

    /// Resample `buffer` to 16 kHz mono. Returns nil when the input is empty
    /// or the converter setup fails. Already-16-kHz-mono buffers short-circuit
    /// and pass through unchanged.
    func resample(_ buffer: LiveAudioBuffer) -> LiveAudioBuffer? {
        guard !buffer.samples.isEmpty else { return nil }
        if let report = driftDetector.observe(buffer) {
            let claimed = String(format: "%.0f", report.claimedRate)
            let observed = String(format: "%.0f", report.observedRate)
            let pct = String(format: "%.1f", report.driftFraction * 100)
            logger.warning(
                "Sample-rate drift detected: claimed=\(claimed, privacy: .public) Hz observed=\(observed, privacy: .public) Hz drift=\(pct, privacy: .public)%",
            )
        }
        if buffer.channelCount == Int(Self.targetChannels),
           buffer.sampleRate == Int(Self.targetSampleRate) {
            return buffer
        }

        guard let converter = ensureConverter(for: buffer) else { return nil }

        // Pack interleaved input samples into an AVAudioPCMBuffer the converter
        // can consume. Frames = total samples / channel count.
        let inputFrames = AVAudioFrameCount(buffer.samples.count / buffer.channelCount)
        guard inputFrames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: inputFrames)
        else { return nil }
        inputBuffer.frameLength = inputFrames
        if let interleavedData = inputBuffer.floatChannelData?[0] {
            buffer.samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    interleavedData.update(from: base, count: buffer.samples.count)
                }
            }
        }

        let ratio = Self.targetSampleRate / Double(buffer.sampleRate)
        let outputCapacity = AVAudioFrameCount(Double(inputFrames) * ratio + 8)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat, frameCapacity: outputCapacity,
        ) else { return nil }

        var error: NSError?
        let feed = FeedOnce(buffer: inputBuffer)
        let status = converter.convert(to: outputBuffer, error: &error) { _, inStatus in
            feed.next(inStatus)
        }
        if let error {
            logger.warning("Resample error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard status != .error, outputBuffer.frameLength > 0 else { return nil }

        let outFrames = Int(outputBuffer.frameLength)
        guard let outPtr = outputBuffer.floatChannelData?[0] else { return nil }
        let samples = Array(UnsafeBufferPointer(start: outPtr, count: outFrames))
        return LiveAudioBuffer(
            samples: samples,
            channelCount: Int(Self.targetChannels),
            sampleRate: Int(Self.targetSampleRate),
            hostTime: buffer.hostTime,
        )
    }

    private func ensureConverter(for buffer: LiveAudioBuffer) -> AVAudioConverter? {
        let formatChanged = inputFormat.map { fmt in
            Int(fmt.sampleRate) != buffer.sampleRate
                || Int(fmt.channelCount) != buffer.channelCount
        } ?? false
        if let existing = converter, !formatChanged {
            return existing
        }
        if formatChanged {
            let oldRate = inputFormat?.sampleRate ?? 0
            let oldChannels = inputFormat?.channelCount ?? 0
            logger.warning(
                "Live resampler input format changed (\(oldRate, privacy: .public)→\(buffer.sampleRate, privacy: .public) Hz, \(oldChannels, privacy: .public)→\(buffer.channelCount, privacy: .public) ch) — rebuilding converter",
            )
        }

        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(buffer.sampleRate),
            channels: AVAudioChannelCount(buffer.channelCount),
            interleaved: true,
        ),
            let output = AVAudioFormat(
                standardFormatWithSampleRate: Self.targetSampleRate,
                channels: Self.targetChannels,
            ),
            let conv = AVAudioConverter(from: input, to: output)
        else {
            logger.error("Failed to build resampler for \(buffer.sampleRate) Hz × \(buffer.channelCount)ch")
            return nil
        }
        converter = conv
        inputFormat = input
        return conv
    }
}

/// Single-shot input provider for `AVAudioConverter.convert(to:error:withInputFrom:)`.
/// First call returns the buffer with `.haveData`; subsequent calls return
/// `.noDataNow` so the converter stops asking. Reference-typed because the
/// converter's input callback is `@Sendable` and would otherwise reject the
/// mutating-var capture pattern used by `MicCaptureHandler`'s equivalent
/// (which predates Swift 6 isolation checking).
private final class FeedOnce: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var fed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if fed {
            outStatus.pointee = .noDataNow
            return nil
        }
        fed = true
        outStatus.pointee = .haveData
        return buffer
    }
}
