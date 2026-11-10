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
        let drops = slot.withLock { queue -> CaptionQueueDrops? in
            defer {
                queue?.finish()
                queue = nil
            }
            return queue?.drops
        }
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

    init(capacitySeconds: TimeInterval) {
        self.capacitySeconds = capacitySeconds
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakeups = stream
        // Nodes stay confined to this lock.
        storage = OSAllocatedUnfairLock(uncheckedState: State(continuation: continuation))
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
            if state.queuedSeconds > capacitySeconds {
                if !state.discontinuity { state.drops.gaps += 1 }
                while state.queuedSeconds > capacitySeconds, let dropped = state.removeFirst() {
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
            let delivery = Delivery(buffer: first.buffer, discontinuity: state.discontinuity)
            state.discontinuity = false
            return delivery
        }
    }

    func finish() {
        storage.withLock { state in
            state.finished = true
            state.continuation.finish()
        }
    }
}
