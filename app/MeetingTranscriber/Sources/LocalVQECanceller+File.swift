// The file-to-file half of LocalVQECanceller: the shape the pipeline calls.
// Split from LocalVQECanceller.swift so the C bridging stays in one place and
// the streaming file I/O in another; the hop loop itself is shared through
// `processHops`.
import AVFoundation
import CLocalVQE
import Foundation

extension LocalVQECanceller {
    /// Frames read, processed and written per block. A multiple of the hop
    /// length so no hop straddles a block, and about a second of audio, which
    /// keeps the resident cost of a two-hour recording in the tens of kilobytes
    /// rather than the hundreds of megabytes an array-shaped call would need.
    private static let blockHops = 64

    /// One report window. Fixed at a second of audio rather than derived from
    /// the block size, so the report keeps the same resolution if the block
    /// size is ever tuned for throughput.
    static let reportWindowSamples = AudioConstants.targetSampleRate

    func cancelEcho(
        micURL: URL, referenceURL: URL, outputURL: URL, referenceLead: TimeInterval,
    ) async throws -> EchoCancellationReport {
        let mic = try AVAudioFile(forReading: micURL)
        let reference = try AVAudioFile(forReading: referenceURL)
        let format = mic.processingFormat

        // Line the reference up with the microphone before a single hop runs.
        // A positive lead means the microphone started late, so its sample 0
        // belongs with reference sample `lead`; seek past that much. A negative
        // one means the reference started late, and the missing head is silence
        // the microphone heard nothing of, so it is padded rather than sought.
        let leadFrames = Int((referenceLead * Double(AudioConstants.targetSampleRate)).rounded())
        var referencePadding = max(0, -leadFrames)
        if leadFrames > 0 {
            reference.framePosition = min(AVAudioFramePosition(leadFrames), reference.length)
        }

        let ctx = localvqe_new(modelPath)
        guard ctx != 0 else {
            throw EchoCancellationError.modelLoadFailed(Self.lastError(ctx: 0))
        }
        defer { localvqe_free(ctx) }

        let hopLength = Int(localvqe_hop_length(ctx))
        // Written beside the destination and moved into place at the end. A
        // caller adopts the output as "the cancelled track", so a run that
        // throws half way must leave nothing that could be adopted.
        let staging = outputURL.deletingLastPathComponent()
            .appendingPathComponent("\(outputURL.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: staging)
        let output = try AVAudioFile(forWriting: staging, settings: Self.outputSettings)

        var windows: [EchoCancellationWindow] = []
        var accumulator = WindowAccumulator(samplesPerWindow: Self.reportWindowSamples)
        var processor = HopProcessor(ctx: ctx, hopLength: hopLength)

        do {
            let blockFrames = AVAudioFrameCount(hopLength * Self.blockHops)
            var produced = [Float]()
            produced.reserveCapacity(Int(blockFrames))
            while mic.framePosition < mic.length {
                try Task.checkCancellation()
                await Task.yield()
                let micBlock = try Self.read(mic, frames: blockFrames, format: format)
                // Only ever read what this block will use. Reading a whole
                // block and trimming it to fit the padding threw the trimmed
                // frames away with the file already advanced past them, so
                // every later block came out that much early: the head was
                // padded and the rest of the recording was misaligned by
                // exactly the amount the padding was meant to correct.
                let pad = min(referencePadding, micBlock.count)
                referencePadding -= pad
                var refBlock = [Float](repeating: 0, count: pad)
                if micBlock.count > pad {
                    // Past the reference's end this reads nothing, and the hop
                    // processor zero-fills, which is how the contract's "a
                    // shorter reference is silence" is actually kept.
                    refBlock += try Self.read(
                        reference, frames: AVAudioFrameCount(micBlock.count - pad), format: format,
                    )
                }
                produced.removeAll(keepingCapacity: true)
                try processor.process(mic: micBlock, reference: refBlock) { hop in
                    produced.append(contentsOf: hop)
                }
                try Self.write(produced[...], to: output, format: format)
                accumulator.add(
                    mic: micBlock, reference: refBlock, output: produced, into: &windows,
                )
            }
            accumulator.flush(into: &windows)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: staging, to: outputURL)
        return EchoCancellationReport(windows: windows)
    }

    /// 16-bit PCM, matching what `AudioMixer.saveWAV` writes for every other
    /// intermediate in the pipeline. A cancelled track that differed in format
    /// from the one it replaces would make every downstream reader's behaviour
    /// depend on whether cancellation ran.
    private static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioConstants.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
    }

    /// The three `bufferCreationFailed` guards below are unreachable as these
    /// two are called, and stay in rather than becoming force-unwraps.
    /// `AVAudioPCMBuffer` returns nil for a zero capacity or a format it
    /// cannot represent; both callers rule the first out before they ask, and
    /// the format is the one the file handed back. They are the boundary of
    /// what this file can promise, not dead code, and a crash is a worse way
    /// to find out the assumption stopped holding.
    private static func read(
        _ file: AVAudioFile, frames: AVAudioFrameCount, format: AVAudioFormat,
    ) throws -> [Float] {
        let remaining = file.length - file.framePosition
        guard remaining > 0 else { return [] }
        let wanted = AVAudioFrameCount(min(Int64(frames), remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted) else {
            throw AudioMixerError.bufferCreationFailed
        }
        try file.read(into: buffer, frameCount: wanted)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func write(
        _ samples: ArraySlice<Float>, to file: AVAudioFile, format: AVAudioFormat,
    ) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count),
        ) else {
            throw AudioMixerError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let destination = buffer.floatChannelData?[0] else {
            throw AudioMixerError.bufferCreationFailed
        }
        for (offset, sample) in samples.enumerated() {
            destination[offset] = sample
        }
        try file.write(from: buffer)
    }
}

/// Rolls per-hop energies up into the report's one-second windows.
///
/// A separate value rather than three running variables in the loop: the roll
/// over a window boundary is the part that is easy to get wrong, and as a type
/// it can be tested without a model, a file, or the C library.
struct WindowAccumulator {
    let samplesPerWindow: Int
    private var micEnergy = 0.0
    private var refEnergy = 0.0
    private var outEnergy = 0.0
    private var windowSamples = 0

    init(samplesPerWindow: Int) {
        self.samplesPerWindow = samplesPerWindow
    }

    /// Folds one block of audio in, emitting a window every time the boundary
    /// is crossed. A block is about a second and a window is exactly one, so a
    /// block can complete a window and start the next; the loop rather than a
    /// single check is what keeps the two sizes independent, so the block can
    /// be tuned for throughput without changing the report's resolution.
    mutating func add(
        mic: [Float], reference: [Float], output: [Float],
        into windows: inout [EchoCancellationWindow],
    ) {
        var offset = 0
        while offset < output.count {
            let take = min(samplesPerWindow - windowSamples, output.count - offset)
            let range = offset ..< (offset + take)
            micEnergy += Self.energy(mic[range.clamped(to: mic.indices)])
            refEnergy += Self.energy(reference[range.clamped(to: reference.indices)])
            outEnergy += Self.energy(output[range])
            windowSamples += take
            offset += take
            if windowSamples >= samplesPerWindow {
                windows.append(current())
                reset()
            }
        }
    }

    /// Emits the trailing partial window, if any. A recording is almost never
    /// a whole number of seconds, and dropping the remainder would silently
    /// lose the end of a short one.
    mutating func flush(into windows: inout [EchoCancellationWindow]) {
        guard windowSamples > 0 else { return }
        windows.append(current())
        reset()
    }

    private func current() -> EchoCancellationWindow {
        let n = Double(max(windowSamples, 1))
        let refRMS = (refEnergy / n).squareRoot()
        let micRMS = (micEnergy / n).squareRoot()
        let outRMS = (outEnergy / n).squareRoot()
        return EchoCancellationWindow(
            referenceDBFS: Float(refRMS > 0 ? 20 * log10(refRMS) : -120),
            // Same arithmetic as `EchoReductionVerdict.reductionDb`, on running
            // sums rather than on buffers the streaming path never holds whole.
            reductionDb: Float(20 * log10(max(micRMS, 1e-12) / max(outRMS, 1e-12))),
        )
    }

    private mutating func reset() {
        micEnergy = 0
        refEnergy = 0
        outEnergy = 0
        windowSamples = 0
    }

    private static func energy(_ samples: some Collection<Float>) -> Double {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    }
}
