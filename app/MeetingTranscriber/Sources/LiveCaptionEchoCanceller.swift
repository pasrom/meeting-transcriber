import AudioTapLib
import CLocalVQE
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

protocol LiveCaptionHopCancelling: AnyObject {
    var hopLength: Int { get }
    func process(mic: [Float], reference: [Float]) throws -> [Float]
    /// Returns the streaming state to its initial zeros, keeping the loaded model.
    func reset()
}

actor LiveCaptionEchoCanceller: LiveCaptionPipeline {
    typealias Factory = @Sendable () throws -> (any LiveCaptionHopCancelling)?

    private let pipeline: any LiveCaptionPipeline
    private let reference: LiveCaptionEchoReference
    private let factory: Factory
    private let clock: @Sendable () -> TimeInterval
    private var processor: (any LiveCaptionHopCancelling)?
    private var initialized = false
    /// The model is unavailable, failed, or the recording was flushed: pass the microphone through.
    private var passingThrough = false
    private var pending: [Float] = []
    private var pendingStart: TimeInterval = 0
    private var timeline = LiveAudioTimeline()
    private var lastEnd: TimeInterval = 0
    private var processedSamples = 0
    private var zeroFilledSamples = 0
    private var processingSeconds: TimeInterval = 0
    private var bypassing = false
    private var bypassedSamples = 0
    private var cancellerLoad = BusyWindow()
    private var asrLoad = BusyWindow()
    private var referenceMoves = 0

    init(
        pipeline: any LiveCaptionPipeline,
        reference: LiveCaptionEchoReference,
        factory: @escaping Factory,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    ) {
        self.pipeline = pipeline
        self.reference = reference
        self.clock = clock
        self.factory = factory
    }

    var isCancelling: Bool {
        processor != nil && !passingThrough
    }

    var zeroFilledSeconds: TimeInterval {
        Double(zeroFilledSamples) / 16000
    }

    func ingest(_ buffer: LiveAudioBuffer, backlog: @Sendable () -> TimeInterval) async {
        guard buffer.hostTime > 0, buffer.sampleRate == 16000, buffer.channelCount == 1 else {
            if timeline.isAnchored {
                await deliverPending(backlog: backlog)
                timeline.reset()
                processor?.reset()
            }
            await pipeline.ingest(buffer, backlog: backlog)
            return
        }
        initialize()
        guard !passingThrough else {
            await pipeline.ingest(buffer, backlog: backlog)
            return
        }
        let duration = Double(buffer.samples.count) / 16000
        let placed = timeline.place(stampedEnd: SampleRateDriftDetector.machTicksToSeconds(buffer.hostTime), duration: duration)
        if placed.shift == .realigned {
            // The pending samples sat on the same misplaced timeline; they move with it.
            pendingStart += placed.delta
            if abs(placed.delta) > LiveCaptionEchoReference.contextShiftLimit { processor?.reset() }
        } else if placed.shift != .kept {
            // A moved timeline shifts the mic-to-reference lag, which LocalVQE does not follow mid-context.
            await deliverPending(backlog: backlog)
            processor?.reset()
            if placed.shift == .forward {
                // Audio is missing: do not let ASR splice the two sides of the gap.
                await pipeline.flush()
                await pipeline.reset()
            }
        }
        if pending.isEmpty { pendingStart = placed.start }
        lastEnd = placed.start + duration
        pending.append(contentsOf: buffer.samples)
        updateBypass(backlog: backlog)
        while !bypassing, let processor, pending.count >= processor.hopLength, referenceReady(hop: processor.hopLength) {
            await deliver(count: processor.hopLength, backlog: backlog)
            if !passingThrough { updateBypass(backlog: backlog) }
        }
        if bypassing {
            bypassedSamples += pending.count
            await deliverPending(backlog: backlog)
        } else if passingThrough {
            await deliverPending(backlog: backlog)
        }
    }

    /// Keeps `bypassing` and the ASR load: a feed reset does not make a backed-up consumer faster.
    func reset() async {
        pending = []
        timeline.reset()
        cancellerLoad = BusyWindow()
        processor?.reset()
        await pipeline.reset()
    }

    func flush() async {
        await deliverPending { .infinity }
        await pipeline.flush()
        guard processor != nil else { return }
        logger.notice(
            "Live caption echo cancellation finished processed=\(Double(self.processedSamples) / 16000, privacy: .public)s processing=\(self.processingSeconds, privacy: .public)s bypassed=\(Double(self.bypassedSamples) / 16000, privacy: .public)s zeroFilledReference=\(self.zeroFilledSeconds, privacy: .public)s",
        )
        // The recording is over: free the context instead of holding it until the next one.
        self.processor = nil
        passingThrough = true
    }

    /// Waits up to `referenceWait` of mic audio for app audio that is on its way to cover the hop.
    private func referenceReady(hop: Int) -> Bool {
        let hopEnd = pendingStart + Double(hop) / 16000
        // Half a sample of slack: both ends are sums of buffer durations.
        guard let referenceEnd = reference.end, referenceEnd + 0.5 / 16000 < hopEnd else { return true }
        return lastEnd - hopEnd >= Self.referenceWait
    }

    private func updateBypass(backlog: @Sendable () -> TimeInterval) {
        // Under memory pressure a hop can take seconds; uncancelled audio beats audio the full queue drops.
        // Pass through only when canceller + ASR fall behind real time and ASR alone still keeps up, so a
        // slow Whisper decode or a held language-probe replay does not disable cancellation while draining.
        let queued = backlog()
        if bypassing, queued <= Self.resumeBacklog {
            bypassing = false
            cancellerLoad = BusyWindow()
            processor?.reset()
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
        let began = clock()
        do {
            processor = try factory()
        } catch {
            passingThrough = true
            logger.notice("Live caption echo cancellation unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        guard let processor else {
            passingThrough = true
            logger.notice("Live caption echo cancellation unavailable: model not present")
            return
        }
        logger.notice(
            "Live caption echo cancellation active hop=\(processor.hopLength, privacy: .public) load=\(self.clock() - began, privacy: .public)s",
        )
    }

    private func fail(_ reason: String) {
        guard !passingThrough else { return }
        passingThrough = true
        processor = nil
        logger.error("Live caption echo cancellation failed; passing microphone through: \(reason, privacy: .public)")
    }

    /// In hops while cancelling: a wait on the reference can leave more than one hop pending.
    private func deliverPending(backlog: @Sendable () -> TimeInterval) async {
        while !pending.isEmpty {
            let hop = isCancelling && !bypassing ? processor?.hopLength ?? pending.count : pending.count
            await deliver(count: min(hop, pending.count), backlog: backlog)
        }
    }

    private func deliver(count: Int, backlog: @Sendable () -> TimeInterval) async {
        let mic = Array(pending.prefix(count))
        let start = pendingStart
        let audioSeconds = Double(count) / 16000
        pending.removeFirst(count)
        pendingStart += audioSeconds
        var output = mic
        if let processor, !bypassing, !passingThrough {
            var padded = mic
            padded.append(contentsOf: repeatElement(0, count: processor.hopLength - count))
            let app = reference.samples(from: start, count: processor.hopLength)
            if app.moves != referenceMoves {
                referenceMoves = app.moves
                processor.reset()
            }
            zeroFilledSamples += min(count, app.missing)
            let began = clock()
            do {
                output = try Array(processor.process(mic: padded, reference: app.samples).prefix(count))
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
    static let referenceWait: TimeInterval = 0.1

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
    /// Below this much audio and busy time a share is noise: one slow hop of a fresh context is not a trend.
    static let minimumEvidence: TimeInterval = 0.25

    private var entries: [(audio: TimeInterval, busy: TimeInterval)] = []
    private var audio: TimeInterval = 0
    private var busy: TimeInterval = 0

    var share: Double {
        guard audio > 0, audio >= Self.minimumEvidence || busy >= Self.minimumEvidence else { return 0 }
        return busy / audio
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
        let options = localvqe_options_new()
        defer { localvqe_options_free(options) }
        guard localvqe_options_set_model_path(options, modelPath) == 0 else {
            throw EchoCancellationError.modelLoadFailed("model path rejected")
        }
        // One thread: the default four wait on each other every 16 ms hop, so one descheduled
        // thread stalls the hop; under load one thread had the shorter tail.
        guard localvqe_options_set_threads(options, 1) == 0 else {
            throw EchoCancellationError.modelLoadFailed("thread count rejected")
        }
        let ctx = localvqe_new_with_options(options)
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

    func reset() {
        localvqe_reset(processor.ctx)
    }
}
