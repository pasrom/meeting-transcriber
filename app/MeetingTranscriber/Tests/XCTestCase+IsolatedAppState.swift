@testable import MeetingTranscriber
import XCTest

/// `AppState`, `AppSettings` and `PipelineController` over this test's own
/// defaults suite and temp folders, the pattern `AppStateTests` uses. That
/// covers the settings and the pipeline's logs, snapshot and staging folder,
/// which the defaults would point at the real ones. It is not a full
/// sandbox: whatever else `AppState.init` touches at launch still resolves
/// against the real app paths, as it does in `AppStateTests`.
@MainActor
extension XCTestCase {
    /// Settings over a per-test defaults suite, removed again at teardown.
    func makeIsolatedSettings() throws -> AppSettings {
        let suite = "\(type(of: self))-\(getpid())-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(DefaultsSuite.open(suite))
        addTeardownBlock { DefaultsSuite.remove(suite) }
        return try AppSettings(
            defaults: defaults,
            defaultOutputDir: makeTempDirectory(prefix: "isolated_output"),
        )
    }

    /// A pipeline environment of temp folders with no staging recovery,
    /// starting with `initialQueue` when one is given.
    func makeIsolatedPipelineEnvironment(
        initialQueue: PipelineQueue? = nil,
    ) throws -> PipelineController.QueueEnvironment {
        try IsolatedQueueEnvironment.make(
            logDir: makeTempDirectory(prefix: "isolated_log"), initialQueue: initialQueue,
        )
    }

    /// A bare queue whose logs, snapshot and staging folder are temp folders,
    /// for a test that only needs somewhere to enqueue. A queue writes its
    /// snapshot in the background, so a test that enqueues into the app's own
    /// folder leaves a job there for the installed app to run.
    func makeIsolatedQueue() throws -> PipelineQueue {
        let environment = try makeIsolatedPipelineEnvironment()
        return PipelineQueue(logDir: environment.logDir, stagingDir: environment.stagingDir)
    }

    func makeIsolatedAppState(
        notifier: any AppNotifying = SilentNotifier(), initialQueue: PipelineQueue? = nil,
    ) throws -> AppState {
        try AppState(
            pipelineEnvironment: makeIsolatedPipelineEnvironment(initialQueue: initialQueue),
            settings: makeIsolatedSettings(),
            notifier: notifier,
        )
    }

    func makeIsolatedPipelineController(initialQueue: PipelineQueue? = nil) throws -> PipelineController {
        try PipelineController(
            settings: makeIsolatedSettings(),
            notifier: SilentNotifier(),
            queueEnvironment: makeIsolatedPipelineEnvironment(initialQueue: initialQueue),
        )
    }
}
