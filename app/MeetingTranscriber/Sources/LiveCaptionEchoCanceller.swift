import AudioTapLib
import CLocalVQE
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

protocol LiveCaptionHopCancelling: AnyObject {
    var hopLength: Int { get }
    func process(mic: [Float], reference: [Float]) throws -> [Float]
}

actor LiveCaptionEchoCanceller: LiveCaptionPipeline {
    typealias Factory = @Sendable () throws -> (any LiveCaptionHopCancelling)?

    private let pipeline: any LiveCaptionPipeline
    private let reference: LiveCaptionEchoReference
    private let factory: Factory
    private let clock: @Sendable () -> TimeInterval
    private var processor: (any LiveCaptionHopCancelling)?
    private var gate: LiveCaptionEchoGate?
    private var initialized = false
    private var failed = false
    private var pending: [Float] = []
    private var pendingStart: TimeInterval = 0
    private var lastEnd: TimeInterval?
    private var processedSamples = 0
    private var processingSeconds: TimeInterval = 0
    private var bypassing = false
    private var bypassedSamples = 0
    private var cancellerLoad = BusyWindow()
    private var asrLoad = BusyWindow()
    private var loggedEnd = false

    init(
        pipeline: any LiveCaptionPipeline,
        reference: LiveCaptionEchoReference,
        factory: @escaping Factory = LiveCaptionEchoCanceller.makeDefaultProcessor,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    ) {
        self.pipeline = pipeline
        self.reference = reference
        self.clock = clock
        self.factory = factory
    }

    func ingest(_ buffer: LiveAudioBuffer, backlog: @Sendable () -> TimeInterval) async {
        guard buffer.hostTime > 0, buffer.sampleRate == 16000, buffer.channelCount == 1 else {
            if let gate {
                await gate.ingest(buffer, backlog: backlog)
                return
            }
            if lastEnd != nil {
                await deliverPending(backlog: backlog)
                lastEnd = nil
                recreateProcessor()
            }
            await pipeline.ingest(buffer, backlog: backlog)
            return
        }
        initialize()
        if let gate {
            await gate.ingest(buffer, backlog: backlog)
            return
        }
        guard !failed else {
            await pipeline.ingest(buffer, backlog: backlog)
            return
        }
        let duration = Double(buffer.samples.count) / 16000
        let stampedStart = SampleRateDriftDetector.machTicksToSeconds(buffer.hostTime) - duration
        // Stamps carry callback delivery delay; a mid-context alignment shift stops LocalVQE cancelling,
        // so advance by sample count and re-anchor only on a real gap.
        if let lastEnd, abs(stampedStart - lastEnd) > 0.1 {
            await deliverPending(backlog: backlog)
            recreateProcessor()
            await pipeline.flush()
            await pipeline.reset()
            self.lastEnd = nil
        }
        let start = lastEnd ?? stampedStart
        if pending.isEmpty { pendingStart = start }
        lastEnd = start + duration
        pending.append(contentsOf: buffer.samples)
        updateBypass(backlog: backlog)
        while !bypassing, let processor, pending.count >= processor.hopLength {
            await deliver(count: processor.hopLength, backlog: backlog)
            if !failed { updateBypass(backlog: backlog) }
        }
        if bypassing {
            bypassedSamples += pending.count
            await deliverPending(backlog: backlog)
        } else if failed {
            await deliverPending(backlog: backlog)
        }
    }

    func reset() async {
        pending = []
        lastEnd = nil
        cancellerLoad = BusyWindow()
        if let gate {
            await gate.reset()
        } else {
            recreateProcessor()
            await pipeline.reset()
        }
    }

    func flush() async {
        if let gate {
            await gate.flush()
        } else {
            await deliverPending { .infinity }
            await pipeline.flush()
        }
        if initialized, gate == nil, !loggedEnd {
            loggedEnd = true
            let seconds = Double(processedSamples) / 16000
            logger
                .notice(
                    "Live caption echo cancellation finished processed=\(seconds, privacy: .public)s processing=\(self.processingSeconds, privacy: .public)s bypassed=\(Double(self.bypassedSamples) / 16000, privacy: .public)s",
                )
        }
    }

    private func updateBypass(backlog: @Sendable () -> TimeInterval) {
        // Under memory pressure a hop can take seconds; uncancelled audio beats audio the full queue drops.
        // Pass through only when canceller + ASR fall behind real time and ASR alone still keeps up, so a
        // slow Whisper decode or a held language-probe replay does not disable cancellation while draining.
        let queued = backlog()
        if bypassing, queued <= Self.resumeBacklog {
            bypassing = false
            cancellerLoad = BusyWindow()
            recreateProcessor()
            logger.notice("Live caption echo cancellation resumed")
        } else if !bypassing,
                  queued > Self.bypassBacklog,
                  asrLoad.share < Self.bypassASRShare,
                  cancellerLoad.share + asrLoad.share >= Self.bypassASRShare {
            bypassing = true
            logger.notice("Live caption echo cancellation behind by \(queued, privacy: .public)s; passing microphone through")
        }
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        var reason = "model not present"
        do {
            processor = try factory()
        } catch {
            reason = String(describing: error)
        }
        if let processor {
            logger.notice("Live caption echo cancellation active hop=\(processor.hopLength, privacy: .public)")
        } else {
            gate = LiveCaptionEchoGate(pipeline: pipeline, reference: reference)
            logger.notice("Live caption echo cancellation unavailable: \(reason, privacy: .public)")
        }
    }

    private func recreateProcessor() {
        guard initialized, gate == nil, !failed else { return }
        processor = nil
        do {
            processor = try factory()
            if processor == nil { fail("context recreation unavailable") }
        } catch {
            fail(String(describing: error))
        }
    }

    private func fail(_ reason: String) {
        guard !failed else { return }
        failed = true
        processor = nil
        logger.error("Live caption echo cancellation failed; passing microphone through: \(reason, privacy: .public)")
    }

    private func deliverPending(backlog: @Sendable () -> TimeInterval) async {
        guard !pending.isEmpty else { return }
        await deliver(count: pending.count, backlog: backlog)
    }

    private func deliver(count: Int, backlog: @Sendable () -> TimeInterval) async {
        let mic = Array(pending.prefix(count))
        let start = pendingStart
        let audioSeconds = Double(count) / 16000
        pending.removeFirst(count)
        pendingStart += audioSeconds
        var output = mic
        if let processor, !bypassing {
            var padded = mic
            padded.append(contentsOf: repeatElement(0, count: processor.hopLength - count))
            let app = reference.samples(from: start, count: processor.hopLength)
            let began = clock()
            do {
                output = try Array(processor.process(mic: padded, reference: app).prefix(count))
                processedSamples += count
            } catch {
                fail(String(describing: error))
            }
            let hopBusy = clock() - began
            processingSeconds += hopBusy
            cancellerLoad.record(audio: audioSeconds, busy: hopBusy)
        }
        let handedOff = clock()
        await pipeline.ingest(
            LiveAudioBuffer(
                samples: output, channelCount: 1, sampleRate: 16000,
                hostTime: SampleRateDriftDetector.secondsToMachTicks(max(0, start + audioSeconds)),
            ),
            backlog: backlog,
        )
        asrLoad.record(audio: audioSeconds, busy: clock() - handedOff)
    }

    private static let bypassBacklog: TimeInterval = 1
    private static let resumeBacklog: TimeInterval = 0.25
    /// Processing seconds per audio second above which the consumer cannot keep up with real time.
    private static let bypassASRShare = 1.0

    nonisolated static func makeDefaultProcessor() throws -> (any LiveCaptionHopCancelling)? {
        switch LocalVQEModel.resolve() {
        case let .found(path): try LocalVQELiveHopProcessor(modelPath: path)
        case .absent: nil
        case .overrideMissing: throw EchoCancellationError.modelLoadFailed("model override missing")
        }
    }
}

/// Time spent per second of audio, over the last second of audio.
private struct BusyWindow {
    private var entries: [(audio: TimeInterval, busy: TimeInterval)] = []
    private var audio: TimeInterval = 0
    private var busy: TimeInterval = 0

    var share: Double {
        audio > 0 ? busy / audio : 0
    }

    mutating func record(audio: TimeInterval, busy: TimeInterval) {
        entries.append((audio, busy))
        self.audio += audio
        self.busy += busy
        while let first = entries.first, self.audio - first.audio >= 1 {
            entries.removeFirst()
            self.audio -= first.audio
            self.busy -= first.busy
        }
    }
}

// The non-Sendable C context stays owned and used by the caption actor.
private final class LocalVQELiveHopProcessor: LiveCaptionHopCancelling {
    private var processor: HopProcessor
    var hopLength: Int {
        processor.hopLength
    }

    init(modelPath: String) throws {
        // One thread: the default four wait on each other every 16 ms hop, so one descheduled
        // thread stalls the hop; under load one thread had the shorter tail.
        let options = localvqe_options_new()
        localvqe_options_set_model_path(options, modelPath)
        localvqe_options_set_threads(options, 1)
        let ctx = localvqe_new_with_options(options)
        localvqe_options_free(options)
        guard ctx != 0 else {
            throw EchoCancellationError.modelLoadFailed(LocalVQECanceller.lastError(ctx: 0))
        }
        let hopLength = Int(localvqe_hop_length(ctx))
        guard hopLength > 0 else {
            localvqe_free(ctx)
            throw EchoCancellationError.modelLoadFailed("invalid hop length \(hopLength)")
        }
        processor = HopProcessor(ctx: ctx, hopLength: hopLength)
    }

    deinit { localvqe_free(processor.ctx) }

    func process(mic: [Float], reference: [Float]) throws -> [Float] {
        var output: [Float] = []
        try processor.process(mic: mic, reference: reference) { output.append(contentsOf: $0) }
        return output
    }
}
