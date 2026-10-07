@testable import MeetingTranscriber
import XCTest

// Doubles shared by the quit tests.

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
