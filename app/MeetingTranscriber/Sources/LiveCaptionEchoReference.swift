import AudioTapLib
import Foundation
import os

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveTranscription")

/// Places live 16 kHz buffers on a sample-count timeline anchored at the first buffer's stamp.
///
/// Callback stamps are forward times and carry delivery delay, so they are not used per buffer:
/// a lone late stamp (jitter) or a burst of buffers stamped together after a stalled queue
/// (offsets falling by each buffer's length) keeps the timeline. Only an offset over
/// `tolerance` that holds steady for `confirmSpan` of audio moves it, by the smallest offset seen.
/// Inside the band it follows the smallest offset per second of audio, so a late anchor or clock
/// drift is corrected before it builds up.
struct LiveAudioTimeline {
    enum Shift: Equatable {
        case kept
        /// Stamps ran ahead of the sample count: audio was lost.
        case forward
        /// Stamps fell behind the sample count: no audio was lost.
        case backward
        /// A correction inside the band: earlier placements were off by `delta`, nothing was lost.
        case realigned
    }

    struct Placement: Equatable {
        var start: TimeInterval
        var shift = Shift.kept
        /// How far the timeline moved, and how many buffers before this one belong after the move.
        var delta: TimeInterval = 0
        var earlierBuffers = 0
    }

    static let tolerance: TimeInterval = 0.1
    static let confirmSpan: TimeInterval = 0.2
    static let steadySlack: TimeInterval = 0.02
    /// In-band offsets up to this are left alone; a quarter of a 16 ms LocalVQE hop.
    static let realignSlack: TimeInterval = 0.004
    static let realignBlock: TimeInterval = 1
    /// Delay only adds to a stamp, so a late offset must hold this many blocks before it counts.
    static let realignLateBlocks = 4

    private var nextStart: TimeInterval?
    private var candidate: (first: TimeInterval, smallest: TimeInterval, span: TimeInterval, buffers: Int)?
    private var block: (span: TimeInterval, smallest: TimeInterval)?
    private var blockMinima: [TimeInterval] = []

    var isAnchored: Bool {
        nextStart != nil
    }

    mutating func place(stampedEnd: TimeInterval, duration: TimeInterval) -> Placement {
        let stampedStart = stampedEnd - duration
        guard let expected = nextStart else {
            nextStart = stampedEnd
            return Placement(start: stampedStart)
        }
        let offset = stampedStart - expected
        var placement = Placement(start: expected)
        if abs(offset) <= Self.tolerance {
            candidate = nil
            if let delta = realignment(offset: offset, duration: duration) {
                placement = Placement(start: expected + delta, shift: .realigned, delta: delta)
            }
        } else if var steady = candidate, (offset > 0) == (steady.first > 0),
                  abs(offset - steady.first) <= Self.steadySlack {
            if steady.span + duration >= Self.confirmSpan {
                // Delivery delay only adds to a stamp, so the smallest offset is the closest to true.
                let delta = min(steady.smallest, offset)
                placement = Placement(
                    start: expected + delta, shift: delta > 0 ? .forward : .backward,
                    delta: delta, earlierBuffers: steady.buffers,
                )
                candidate = nil
                block = nil
                blockMinima = []
            } else {
                steady.smallest = min(steady.smallest, offset)
                steady.span += duration
                steady.buffers += 1
                candidate = steady
            }
        } else {
            candidate = (offset, offset, duration, 1)
        }
        nextStart = placement.start + duration
        return placement
    }

    mutating func reset() {
        nextStart = nil
        candidate = nil
        block = nil
        blockMinima = []
    }

    /// The smallest in-band offset of each `realignBlock` of audio; an early one corrects at the end of that block.
    private mutating func realignment(offset: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        var current = block ?? (0, offset)
        current.span += duration
        current.smallest = min(current.smallest, offset)
        guard current.span >= Self.realignBlock else {
            block = current
            return nil
        }
        block = nil
        blockMinima = Array((blockMinima + [current.smallest]).suffix(Self.realignLateBlocks))
        let late = blockMinima.count == Self.realignLateBlocks ? blockMinima.min() : nil
        let delta: TimeInterval? = if current.smallest < -Self.realignSlack {
            current.smallest
        } else if let late, late > Self.realignSlack {
            late
        } else {
            nil
        }
        if delta != nil { blockMinima = [] }
        return delta
    }
}

/// The recent app audio the live canceller subtracts, kept by reference on the capture callback.
final class LiveCaptionEchoReference: Sendable {
    private struct Entry {
        var start: TimeInterval
        let buffer: LiveAudioBuffer
        var count: Int

        var end: TimeInterval {
            start + Double(count) / 16000
        }
    }

    private struct State {
        var timeline = LiveAudioTimeline()
        /// Ordered by start and by end, without overlap; a backward shift trims older entries to keep it so.
        var entries: [Entry] = []
        var nextPruneAt: TimeInterval = 0
        var loggedUnsupported = false
        /// Off while echo cancellation is off, so nothing is retained that no canceller reads.
        var collecting = false
        var moves = 0
    }

    static let retainedSeconds: TimeInterval = 15

    private let storage: OSAllocatedUnfairLock<State>

    init(collecting: Bool = true) {
        storage = OSAllocatedUnfairLock(initialState: State(collecting: collecting))
    }

    /// LocalVQE lost cancellation after a mid-context lag step of 16 ms or more (8 ms held), so a
    /// larger move of the reference counts in `moves` and the canceller resets its context.
    static let contextShiftLimit: TimeInterval = 0.008

    func clear(collecting: Bool) {
        storage.withLock { $0 = State(collecting: collecting) }
    }

    /// Keeps what was collected, so app audio held for a language-probe replay stays.
    func startCollecting() {
        storage.withLock { $0.collecting = true }
    }

    func append(_ buffer: LiveAudioBuffer) {
        guard storage.withLock({ $0.collecting }) else { return }
        guard buffer.hostTime > 0, buffer.sampleRate == 16000, buffer.channelCount == 1 else {
            let first = storage.withLock { state in
                if state.timeline.isAnchored { state.moves += 1 }
                state.entries = []
                state.timeline.reset()
                defer { state.loggedUnsupported = true }
                return !state.loggedUnsupported
            }
            if first {
                logger.notice(
                    "Live caption echo reference skips unsupported app audio rate=\(buffer.sampleRate, privacy: .public) channels=\(buffer.channelCount, privacy: .public)",
                )
            }
            return
        }
        let stampedEnd = SampleRateDriftDetector.machTicksToSeconds(buffer.hostTime)
        let duration = Double(buffer.samples.count) / 16000
        storage.withLock { state in
            let placed = state.timeline.place(stampedEnd: stampedEnd, duration: duration)
            let needsFreshContext = placed.shift == .realigned
                ? abs(placed.delta) > Self.contextShiftLimit : placed.shift != .kept
            if needsFreshContext { state.moves += 1 }
            if placed.shift == .realigned {
                // The whole retained timeline was off by the same amount; moving it all keeps entries contiguous.
                for index in state.entries.indices {
                    state.entries[index].start += placed.delta
                }
            } else if placed.shift != .kept {
                // The buffers that confirmed the move were placed before it; move them with it.
                var moved = Array(state.entries.suffix(placed.earlierBuffers))
                state.entries.removeLast(moved.count)
                for index in moved.indices {
                    moved[index].start += placed.delta
                }
                Self.trim(&state.entries, to: moved.first?.start ?? placed.start)
                state.entries += moved
            }
            let entry = Entry(start: placed.start, buffer: buffer, count: buffer.samples.count)
            state.entries.append(entry)
            if entry.end >= state.nextPruneAt {
                let stale = Self.firstEntry(in: state.entries, endingAfter: entry.end - Self.retainedSeconds)
                state.entries.removeFirst(stale)
                state.nextPruneAt = entry.end + 1
            }
        }
    }

    /// End of the newest app audio on the reference timeline; nil before any arrived.
    var end: TimeInterval? {
        storage.withLock { $0.entries.last?.end }
    }

    /// `count` samples from `start`, zero where no app audio covers it, how many were zero-filled,
    /// and the move count read under the same lock.
    func samples(from start: TimeInterval, count: Int) -> (samples: [Float], missing: Int, moves: Int) {
        let end = start + Double(count) / 16000
        let (overlapping, moves) = storage.withLock { state in
            let first = Self.firstEntry(in: state.entries, endingAfter: start)
            return (Array(state.entries[first...].prefix { $0.start < end }), state.moves)
        }
        var samples = [Float](repeating: 0, count: count)
        var covered = 0
        for entry in overlapping {
            let offset = Int(((entry.start - start) * 16000).rounded())
            let first = max(0, offset)
            let last = min(count, offset + entry.count)
            guard first < last else { continue }
            for target in first ..< last {
                samples[target] = entry.buffer.samples[target - offset]
            }
            covered += last - first
        }
        return (samples, max(0, count - covered), moves)
    }

    private static func firstEntry(in entries: [Entry], endingAfter time: TimeInterval) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].end <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func trim(_ entries: inout [Entry], to start: TimeInterval) {
        while let last = entries.last, last.start >= start {
            entries.removeLast()
        }
        guard let last = entries.indices.last else { return }
        entries[last].count = min(entries[last].count, max(0, Int(((start - entries[last].start) * 16000).rounded())))
    }
}
