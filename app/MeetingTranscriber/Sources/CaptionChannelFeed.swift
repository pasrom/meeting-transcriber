import AudioTapLib
import Foundation
import os

/// A duration-bounded audio queue with one serialized consumer per channel.
@MainActor
final class CaptionChannelFeed {
    /// Normalization stays on the consumer; nil drops the buffer.
    typealias Transform = (LiveAudioBuffer) -> LiveAudioBuffer?

    private let maxQueuedSeconds: TimeInterval

    init(maxQueuedSeconds: TimeInterval) {
        self.maxQueuedSeconds = maxQueuedSeconds
    }

    private let slot = OSAllocatedUnfairLock<CaptionAudioQueue?>(initialState: nil)
    /// Lock-boxed for nonisolated deinit and retire-before-rebind ownership.
    private let consumerBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Stop inference when settings discard the owner while sinks are still installed.
    deinit {
        consumerBox.withLock { task in
            task?.cancel()
            task = nil
        }
        slot.withLock { queue in
            queue?.finish()
            queue = nil
        }
    }

    /// No task spawn or actor hop on the capture callback.
    var sink: LiveAudioSink {
        let slot = slot
        return { buffer in
            slot.withLock { $0?.push(buffer) }
        }
    }

    /// Retire first; keep stateful transforms confined to the new consumer.
    func bind(
        to pipeline: any LiveCaptionPipeline,
        makeTransform: @escaping @Sendable () -> Transform = { \.self },
    ) async {
        await retire()
        let queue = CaptionAudioQueue(capacitySeconds: maxQueuedSeconds)
        slot.withLock { $0 = queue }
        startConsumer(queue: queue, pipeline: pipeline, makeTransform: makeTransform)
    }

    /// Accept capture with no consumer while the caption language is detected,
    /// holding up to 60 s; nothing is decoded until `installHeld` runs.
    func hold() async {
        await retire()
        let queue = CaptionAudioQueue(capacitySeconds: maxQueuedSeconds, initialCapacitySeconds: 60)
        slot.withLock { $0 = queue }
    }

    /// Start the consumer on the held queue, replaying all of it (`replayLast` nil)
    /// or only its newest seconds, trimmed under the capture lock. No-op after the
    /// slot closed or once consuming.
    func installHeld(
        to pipeline: any LiveCaptionPipeline,
        replayLast: TimeInterval? = nil,
        makeTransform: @escaping @Sendable () -> Transform = { \.self },
    ) {
        guard consumerBox.withLock({ $0 == nil }) else { return }
        let held = slot.withLock { queue -> CaptionAudioQueue? in
            if let replayLast { queue?.keepNewest(seconds: replayLast) }
            return queue
        }
        guard let held else { return }
        startConsumer(queue: held, pipeline: pipeline, makeTransform: makeTransform)
    }

    /// Stop accepting capture and cancel the consumer without draining it;
    /// `retire()` still awaits the cancelled task.
    func cancel() {
        closeAcceptance()
        consumerBox.withLock { $0?.cancel() }
    }

    /// Drops of the queue `closeAcceptance()` closed, until `retire()` reports them.
    private var closedDrops: CaptionQueueDrops?

    /// Stop accepting capture synchronously, before any caller suspends.
    func closeAcceptance() {
        let drops = slot.withLock { queue -> CaptionQueueDrops? in
            defer {
                queue?.finish()
                queue = nil
            }
            return queue?.drops
        }
        if let drops { closedDrops = drops }
    }

    private func startConsumer(
        queue: CaptionAudioQueue,
        pipeline: any LiveCaptionPipeline,
        makeTransform: @escaping @Sendable () -> Transform,
    ) {
        let consumer = Task.detached(priority: .userInitiated) {
            var transform = makeTransform()
            for await _ in queue.wakeups {
                while !Task.isCancelled, let delivery = queue.pop() {
                    if delivery.discontinuity {
                        transform = makeTransform()
                        await pipeline.reset()
                    }
                    guard let normalized = transform(delivery.buffer) else { continue }
                    await pipeline.ingest(normalized) { queue.queuedSeconds }
                }
            }
        }
        consumerBox.withLock { $0 = consumer }
    }

    /// Stop deliveries and take the old consumer before awaiting its drain.
    /// Returns the audio the retired queue dropped on overflow, nil if none was bound.
    @discardableResult
    func retire() async -> CaptionQueueDrops? {
        closeAcceptance()
        let drops = closedDrops
        closedDrops = nil
        let retiring = consumerBox.withLock { task -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        if let retiring { await retiring.value }
        return drops
    }
}

/// Audio a caption queue discarded on overflow, which never reaches the pipeline.
struct CaptionQueueDrops: Equatable {
    var seconds: TimeInterval = 0
    /// Discontinuities opened, each one pipeline reset.
    var gaps = 0
}

/// Stores buffer references without copying samples on the capture callback.
private final class CaptionAudioQueue: Sendable {
    private let capacitySeconds: TimeInterval

    private final class Node {
        let buffer: LiveAudioBuffer
        let duration: TimeInterval
        var next: Node?

        init(buffer: LiveAudioBuffer, duration: TimeInterval) {
            self.buffer = buffer
            self.duration = duration
        }
    }

    struct Delivery: Sendable {
        let buffer: LiveAudioBuffer
        let discontinuity: Bool
    }

    private struct State {
        let continuation: AsyncStream<Void>.Continuation
        var capacitySeconds: TimeInterval
        var head: Node?
        var tail: Node?
        var queuedSeconds: TimeInterval = 0
        var discontinuity = false
        var finished = false
        var drops = CaptionQueueDrops()

        mutating func removeFirst() -> Node? {
            guard let first = head else { return nil }
            head = first.next
            first.next = nil
            queuedSeconds -= first.duration
            if head == nil {
                tail = nil
                queuedSeconds = 0
            }
            return first
        }
    }

    let wakeups: AsyncStream<Void>
    private let storage: OSAllocatedUnfairLock<State>

    init(capacitySeconds: TimeInterval, initialCapacitySeconds: TimeInterval? = nil) {
        self.capacitySeconds = capacitySeconds
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakeups = stream
        // Nodes stay confined to this lock.
        storage = OSAllocatedUnfairLock(uncheckedState: State(
            continuation: continuation,
            capacitySeconds: max(capacitySeconds, initialCapacitySeconds ?? capacitySeconds),
        ))
    }

    deinit {
        // Release long queues iteratively rather than recursing through nodes.
        storage.withLock { state in
            while state.removeFirst() != nil {}
        }
    }

    var queuedSeconds: TimeInterval {
        storage.withLock { $0.queuedSeconds }
    }

    var drops: CaptionQueueDrops {
        storage.withLock { $0.drops }
    }

    func push(_ buffer: LiveAudioBuffer) {
        guard !buffer.samples.isEmpty, buffer.sampleRate > 0, buffer.channelCount > 0 else { return }
        let duration = Double(buffer.samples.count) / Double(buffer.channelCount) / Double(buffer.sampleRate)
        storage.withLock { state in
            guard !state.finished else { return }
            let node = Node(buffer: buffer, duration: duration)
            if let tail = state.tail { tail.next = node } else { state.head = node }
            state.tail = node
            state.queuedSeconds += duration
            if state.queuedSeconds > state.capacitySeconds {
                if !state.discontinuity { state.drops.gaps += 1 }
                while state.queuedSeconds > state.capacitySeconds, let dropped = state.removeFirst() {
                    state.drops.seconds += dropped.duration
                }
                state.discontinuity = true
            }
            state.continuation.yield(())
        }
    }

    func pop() -> Delivery? {
        storage.withLock { state in
            guard let first = state.removeFirst() else { return nil }
            // A replayed hold keeps its larger bound until it has caught up,
            // or the next capture callback would drop the held audio.
            if state.queuedSeconds <= capacitySeconds {
                state.capacitySeconds = capacitySeconds
            }
            let delivery = Delivery(buffer: first.buffer, discontinuity: state.discontinuity)
            state.discontinuity = false
            return delivery
        }
    }

    /// Drop the oldest held audio beyond `seconds`; a trimmed run starts with a reset.
    /// The hold bound stays until `pop()` has caught up, as for a full replay.
    func keepNewest(seconds: TimeInterval) {
        storage.withLock { state in
            while state.queuedSeconds > seconds, state.removeFirst() != nil {
                state.discontinuity = true
            }
        }
    }

    func finish() {
        storage.withLock { state in
            state.finished = true
            state.continuation.finish()
        }
    }
}
