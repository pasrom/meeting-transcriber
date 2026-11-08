import AudioTapLib
import Foundation
@testable import MeetingTranscriber

/// Continuation-controlled pipeline for deterministic feed drain and overflow tests.
actor RecordingCaptionPipeline: LiveCaptionPipeline {
    enum Event: Equatable {
        case buffer(Float)
        case reset
    }

    private(set) var events: [Event] = []
    private(set) var samples: [Float] = []
    private(set) var peakBacklogSeconds: TimeInterval = 0
    private(set) var backlogSeconds: [TimeInterval] = []
    private var firstIngest: Bool
    private(set) var flushCount = 0

    init(blockFirst: Bool = true) {
        firstIngest = blockFirst
    }

    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func ingest(_ buffer: LiveAudioBuffer, backlog: @Sendable () -> TimeInterval) async {
        if firstIngest {
            firstIngest = false
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                for waiter in blockedWaiters {
                    waiter.resume()
                }
                blockedWaiters.removeAll()
            }
        }
        let pendingSeconds = backlog()
        backlogSeconds.append(pendingSeconds)
        peakBacklogSeconds = max(peakBacklogSeconds, pendingSeconds)
        events.append(.buffer(buffer.samples[0]))
        samples.append(contentsOf: buffer.samples)
    }

    func reset() {
        events.append(.reset)
    }

    func flush() {
        flushCount += 1
    }

    func waitUntilBlocked() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
