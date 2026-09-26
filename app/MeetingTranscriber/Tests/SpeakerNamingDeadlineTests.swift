@testable import MeetingTranscriber
import XCTest

/// When the stale-naming cleanup gives up on a job left in the naming dialog.
///
/// It accepts the auto-names for a job left there longer than a day. The day
/// used to count from `enqueuedAt`, which cannot move because the output
/// basename is anchored on it, so a job that had waited in the queue for a day
/// was resolved the moment it reached the dialog, before anyone saw it.
///
/// Temp-dir cleanup is registered via `makeTempDirectory`'s `addTeardownBlock`.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class SpeakerNamingDeadlineTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "naming_deadline_test")
    }

    private let day: TimeInterval = 86400

    /// A job decoded from a snapshot with `enqueuedAt` two days back, and
    /// optionally the time it entered the naming dialog.
    private func makeOldJob(state: JobState, namingStartedAt: Date? = nil) throws -> PipelineJob {
        let fresh = PipelineJob(
            meetingTitle: "Old Job", appName: "Teams",
            mixPath: tmpDir.appendingPathComponent("old_mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        encoded["enqueuedAt"] = Date().addingTimeInterval(-2 * day).timeIntervalSinceReferenceDate
        encoded["state"] = state.rawValue
        if let namingStartedAt {
            encoded["namingStartedAt"] = namingStartedAt.timeIntervalSinceReferenceDate
        }
        return try JSONDecoder().decode(PipelineJob.self, from: JSONSerialization.data(withJSONObject: encoded))
    }

    private func state(of job: PipelineJob, in queue: PipelineQueue) -> JobState? {
        queue.jobs.first { $0.id == job.id }?.state
    }

    /// The day counts from entering the dialog, not from any earlier point: a
    /// job that waited long in the queue before it got there is owed the same
    /// day as one that did not.
    func testTheNamingDayCountsFromEnteringTheDialog() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        let old = try makeOldJob(state: .generatingProtocol)
        queue.insertJobForTesting(old)

        queue.updateJobState(id: old.id, to: .speakerNamingPending)
        queue.cleanupStalePending(maxAge: day)

        XCTAssertEqual(
            state(of: old, in: queue), .speakerNamingPending,
            "a job that waited in the queue was stale on reaching the dialog",
        )
    }

    /// And the cleanup still fires: a job that entered the dialog two days ago
    /// is resolved, whatever `enqueuedAt` says.
    func testAJobInTheDialogForTwoDaysIsStillResolved() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        let old = try makeOldJob(state: .speakerNamingPending, namingStartedAt: Date().addingTimeInterval(-2 * day))
        queue.insertJobForTesting(old)

        queue.cleanupStalePending(maxAge: day)

        XCTAssertEqual(state(of: old, in: queue), .done)
    }

    /// A late re-diarization leaves the dialog and comes back to it. That is
    /// the same wait, not a new one: restarting the day on every return would
    /// let a job re-run once a day stay pending for ever.
    func testALateReDiarizationDoesNotRestartTheDay() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        let old = try makeOldJob(state: .speakerNamingPending, namingStartedAt: Date().addingTimeInterval(-2 * day))
        queue.insertJobForTesting(old)

        queue.updateJobState(id: old.id, to: .diarizing)
        queue.updateJobState(id: old.id, to: .speakerNamingPending)
        queue.cleanupStalePending(maxAge: day)

        XCTAssertEqual(state(of: old, in: queue), .done, "returning from a re-run restarted the naming day")
    }

    /// A retry is a new run, though, and owes a full day: a job whose failed
    /// run entered the dialog two days ago was otherwise resolved the moment
    /// its retry got there.
    func testARetriedJobGetsAFullDayInTheNamingDialog() throws {
        let queue = PipelineQueue(logDir: tmpDir)
        let old = try makeOldJob(state: .error, namingStartedAt: Date().addingTimeInterval(-2 * day))
        try Data().write(to: XCTUnwrap(old.mixPath))
        queue.insertJobForTesting(old)

        // No engine, so nothing runs the job: move it straight to the dialog.
        // (`awaitProcessing` would wait forever on a job nobody can take.)
        XCTAssertTrue(queue.retryJob(id: old.id))
        queue.updateJobState(id: old.id, to: .speakerNamingPending)
        queue.cleanupStalePending(maxAge: day)

        XCTAssertEqual(
            state(of: old, in: queue), .speakerNamingPending,
            "the retried job was auto-resolved as stale on reaching the dialog",
        )
    }
}
