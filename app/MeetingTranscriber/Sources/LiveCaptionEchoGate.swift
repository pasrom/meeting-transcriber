import AudioTapLib
import Foundation
import os

/// A conservative pre-ASR microphone gate; uncertain audio always reaches the pipeline.
actor LiveCaptionEchoGate: LiveCaptionPipeline {
    private let pipeline: any LiveCaptionPipeline
    private let reference: LiveCaptionEchoReference
    private var pending: [Float] = []
    private var pendingStart: TimeInterval = 0
    private var lastEnd: TimeInterval?
    private var suppressing = false

    init(pipeline: any LiveCaptionPipeline, reference: LiveCaptionEchoReference = LiveCaptionEchoReference()) {
        self.pipeline = pipeline
        self.reference = reference
    }

    func ingest(_ buffer: LiveAudioBuffer, backlog: @Sendable () -> TimeInterval) async {
        guard buffer.hostTime > 0, buffer.sampleRate == 16000, buffer.channelCount == 1 else {
            await deliverTail(backlog: backlog)
            lastEnd = nil
            suppressing = false
            await pipeline.ingest(buffer, backlog: backlog)
            return
        }
        let end = SampleRateDriftDetector.machTicksToSeconds(buffer.hostTime)
        let start = end - Double(buffer.samples.count) / 16000
        if let lastEnd, abs(start - lastEnd) > 0.1 {
            await deliverTail(backlog: backlog)
            await pipeline.flush()
            await pipeline.reset()
            suppressing = false
        }
        if pending.isEmpty { pendingStart = start }
        lastEnd = end
        pending.append(contentsOf: buffer.samples)
        while pending.count >= 16000 {
            let samples = Array(pending.prefix(16000))
            pending.removeFirst(16000)
            let start = pendingStart
            pendingStart += 1
            let app = reference.samples(from: start - EchoBleedDetector.maxLagSeconds, to: start + 1)
            if Self.isEcho(app: app, mic: samples) {
                if !suppressing {
                    // Preserve genuine speech already buffered before the echo began.
                    await pipeline.flush()
                    await pipeline.reset()
                }
                suppressing = true
            } else {
                suppressing = false
                await pipeline.ingest(Self.buffer(samples, endingAt: start + 1), backlog: backlog)
            }
        }
    }

    func reset() async {
        pending = []
        lastEnd = nil
        suppressing = false
        await pipeline.reset()
    }

    func flush() async {
        // Short tails lack enough evidence to suppress safely.
        await deliverTail { .infinity }
        await pipeline.flush()
    }

    private func deliverTail(backlog: @Sendable () -> TimeInterval) async {
        guard !pending.isEmpty else { return }
        let samples = pending
        pending = []
        await pipeline.ingest(Self.buffer(samples, endingAt: pendingStart + Double(samples.count) / 16000), backlog: backlog)
    }

    private static func buffer(_ samples: [Float], endingAt end: TimeInterval) -> LiveAudioBuffer {
        LiveAudioBuffer(
            samples: samples, channelCount: 1, sampleRate: 16000,
            hostTime: SampleRateDriftDetector.secondsToMachTicks(max(0, end)),
        )
    }

    private static func isEcho(app: [Float], mic: [Float]) -> Bool {
        let appEnvelope = EchoBleedDetector.envelope(app, count: app.count, samplesPerFrame: 160)
        let micEnvelope = EchoBleedDetector.envelope(mic, count: mic.count, samplesPerFrame: 160)
        let padding = Int(EchoBleedDetector.maxLagSeconds / EchoBleedDetector.frameSeconds)
        let overlap = min(micEnvelope.count, appEnvelope.count - padding)
        guard overlap >= 80,
              let peak = EchoBleedDetector.peakCorrelation(
                  appEnvelope[padding ..< padding + overlap], micEnvelope[..<overlap],
                  maxLag: padding, centre: 0,
              ), peak.correlation >= 0.95
        else { return false }

        var blocks: [(app: Double, mic: Double)] = []
        for first in stride(from: 0, to: micEnvelope.count, by: 5) {
            let end = min(first + 5, micEnvelope.count)
            let appFirst = padding + first - peak.lag
            let appEnd = padding + end - peak.lag
            guard appFirst >= 0, appEnd <= appEnvelope.count else { return false }
            let appRMS = rms(appEnvelope[appFirst ..< appEnd])
            let micRMS = rms(micEnvelope[first ..< end])
            blocks.append((appRMS, micRMS))
        }
        let floor = pow(10, EchoBleedDetector.silenceFloorDBFS / 20)
        let ratios = blocks.filter { $0.app > floor }.map { $0.mic / $0.app }.sorted()
        guard ratios.count >= 12 else { return false }
        let gain = ratios[ratios.count / 5]
        // Unlike the pooled post-meeting residual, every 50 ms block must fit.
        return blocks.allSatisfy { $0.mic <= gain * $0.app * 1.1 + floor }
            && waveformMatches(app: app, mic: mic, lag: peak.lag)
    }

    private static func waveformMatches(app: [Float], mic: [Float], lag: Int) -> Bool {
        let appSamples = app.map(Double.init)
        let micSamples = mic.map(Double.init)
        let predicted = Int(EchoBleedDetector.maxLagSeconds * 16000) - lag * 160
        for step in 0 ... 320 {
            // Test the envelope's alignment first, then refine outwards by one sample.
            let offset = step.isMultiple(of: 2) ? step / 2 : -(step / 2 + 1)
            let start = predicted + offset
            guard start >= 0, start + mic.count <= app.count else { continue }
            if let correlation = EchoBleedDetector.correlation(
                appSamples[start ..< start + mic.count], micSamples[...],
            ), correlation * correlation >= 0.95 {
                return true
            }
        }
        return false
    }

    private static func rms(_ samples: ArraySlice<Double>) -> Double {
        (samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count)).squareRoot()
    }
}

/// Stores only the recent capture references; analysis and sample copies happen off the callback.
final class LiveCaptionEchoReference: Sendable {
    private struct State {
        var buffers: [LiveAudioBuffer] = []
        var nextPruneAt: TimeInterval = 0
    }

    private let storage = OSAllocatedUnfairLock(initialState: State())

    func clear() {
        storage.withLock { $0 = State() }
    }

    func append(_ buffer: LiveAudioBuffer) {
        guard buffer.hostTime > 0, buffer.sampleRate == 16000, buffer.channelCount == 1 else {
            clear()
            return
        }
        let end = SampleRateDriftDetector.machTicksToSeconds(buffer.hostTime)
        storage.withLock { state in
            state.buffers.append(buffer)
            if end >= state.nextPruneAt {
                let cutoff = end - 15
                state.buffers.removeAll { SampleRateDriftDetector.machTicksToSeconds($0.hostTime) < cutoff }
                state.nextPruneAt = end + 1
            }
        }
    }

    func samples(from start: TimeInterval, to end: TimeInterval) -> [Float] {
        let buffers = storage.withLock { state in
            state.buffers.filter { buffer in
                let bufferEnd = SampleRateDriftDetector.machTicksToSeconds(buffer.hostTime)
                let bufferStart = bufferEnd - Double(buffer.samples.count) / 16000
                return bufferEnd >= start && bufferStart <= end
            }
        }
        guard let first = buffers.first else { return [] }
        let firstEnd = SampleRateDriftDetector.machTicksToSeconds(first.hostTime)
        let firstStart = firstEnd - Double(first.samples.count) / 16000
        var previousEnd = firstStart
        var samples: [Float] = []
        for buffer in buffers {
            let bufferEnd = SampleRateDriftDetector.machTicksToSeconds(buffer.hostTime)
            let bufferStart = bufferEnd - Double(buffer.samples.count) / 16000
            guard abs(bufferStart - previousEnd) <= 0.05 else { return [] }
            samples.append(contentsOf: buffer.samples)
            previousEnd = bufferEnd
        }
        let offset = Int(((start - firstStart) * 16000).rounded())
        let count = Int(((end - start) * 16000).rounded())
        guard offset >= 0, offset < samples.count else { return [] }
        return Array(samples[offset ..< min(offset + count, samples.count)])
    }

    func samples(from start: TimeInterval, count: Int) -> [Float] {
        let end = start + Double(count) / 16000
        let buffers = storage.withLock { state in
            state.buffers.filter { buffer in
                let bufferEnd = SampleRateDriftDetector.machTicksToSeconds(buffer.hostTime)
                let bufferStart = bufferEnd - Double(buffer.samples.count) / 16000
                return bufferEnd > start && bufferStart < end
            }
        }
        var samples = [Float](repeating: 0, count: count)
        for buffer in buffers {
            let bufferEnd = SampleRateDriftDetector.machTicksToSeconds(buffer.hostTime)
            let bufferStart = bufferEnd - Double(buffer.samples.count) / 16000
            let offset = Int(((bufferStart - start) * 16000).rounded())
            let first = max(0, offset)
            let last = min(count, offset + buffer.samples.count)
            guard first < last else { continue }
            for index in first ..< last {
                samples[index] = buffer.samples[index - offset]
            }
        }
        return samples
    }
}
