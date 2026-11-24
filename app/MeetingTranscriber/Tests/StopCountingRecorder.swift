@testable import MeetingTranscriber
import XCTest

// Doubles shared by the quit tests and the stop tests.

/// Counts which stop each recording went through.
@MainActor
final class StopCountingRecorder: RecordingProvider {
    private(set) var startCalled = false
    private(set) var syncStops = 0
    private(set) var offMainStops = 0

    func start(source _: RecordingSource, micDeviceUID _: String?, debugLogging _: Bool) {
        startCalled = true
    }

    func stop() -> RecordingResult {
        syncStops += 1
        return result()
    }

    // Async to match the requirement; what is counted is which stop ran.
    // swiftlint:disable:next async_without_await
    func stopOffMain() async -> RecordingResult {
        offMainStops += 1
        return result()
    }

    private func result() -> RecordingResult {
        RecordingResult(
            mixPath: URL(fileURLWithPath: "/tmp/stop_counting_mix.wav"), appPath: nil, micPath: nil,
            micDelay: 0, recordingStartDate: Date(),
        )
    }
}

/// The mix of a long meeting, held open until the test lets it finish.
/// A thread blocked in `wait()` stands for one busy mixing. The wait
/// also ends on its own after `deadline`, so that a mix wrongly run on
/// the main thread, where the test can no longer reach `release()`,
/// cannot hang the suite: the test then fails instead.
final class MixGate: Sendable {
    static let deadline: Duration = .seconds(5)
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        _ = semaphore.wait(timeout: .now() + .seconds(Int(Self.deadline.components.seconds)))
    }

    func release() {
        semaphore.signal()
    }
}

/// A recorder whose stop does what the real one does at the end of a long
/// meeting: a mix that takes as long as it takes, here until the test
/// releases `gate`. `stop()` does it on the caller's thread, which for a
/// caller on the main actor is the main thread; `stopOffMain()` does it on a
/// thread of its own, as `DualSourceRecorder` does.
@MainActor
final class SlowMixRecorder: RecordingProvider {
    let gate = MixGate()
    /// Counted on the main actor before the mix begins, by either stop.
    private(set) var mixesStarted = 0
    private(set) var mixesFinished = 0
    /// Thrown by either stop once its mix is done, for a recording that
    /// captured nothing.
    var stopError: RecorderError?

    func start(source _: RecordingSource, micDeviceUID _: String?, debugLogging _: Bool) {}

    func stop() throws -> RecordingResult {
        mixesStarted += 1
        gate.wait()
        mixesFinished += 1
        return try result()
    }

    func stopOffMain() async throws -> RecordingResult {
        mixesStarted += 1
        let gate = gate
        await Task.detached { gate.wait() }.value
        mixesFinished += 1
        return try result()
    }

    private func result() throws -> RecordingResult {
        if let stopError { throw stopError }
        return RecordingResult(
            mixPath: URL(fileURLWithPath: "/tmp/slow_mix.wav"), appPath: nil, micPath: nil,
            micDelay: 0, recordingStartDate: Date(),
        )
    }
}

/// A loop that records with `recorder`, polling fast and with a short grace.
@MainActor
func makeSlowMixLoop(
    recorder: SlowMixRecorder, queue: PipelineQueue, detector: any MeetingDetecting = makeSilentDetector(),
) -> WatchLoop {
    let loop = WatchLoop(
        detector: detector,
        recorderFactory: { recorder },
        pipelineQueue: queue,
        pollInterval: 0.05,
        endGracePeriod: 0.1,
    )
    loop.permissionChecker = { .allHealthy }
    return loop
}

/// Stands in for `NSApplication` as the one who asked to quit: replying on
/// the real shared application would end the test process.
@MainActor
final class QuitTestSender: TerminationReplying {
    private(set) var replies: [Bool] = []
    var onReply: (() -> Void)?

    func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        replies.append(shouldTerminate)
        onReply?()
    }
}

@MainActor
extension XCTestCase {
    /// A queue whose writer takes long enough that its write is still in
    /// flight when the test acts: a quit is answered, or the next queue starts.
    func makeSlowSnapshotQueue(in dir: URL) -> PipelineQueue {
        // swiftlint:disable:next trailing_closure
        PipelineQueue(logDir: dir, snapshotWriter: { jobs, url in
            Thread.sleep(forTimeInterval: 0.3)
            try PipelineSnapshot.save(jobs, to: url)
        })
    }
}
