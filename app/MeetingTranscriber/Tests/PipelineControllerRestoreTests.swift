@testable import MeetingTranscriber
import XCTest

/// Signals a rebuilt queue raises while it restores its jobs, observed through
/// `PipelineController.rebuild()`, the only way production restores. The
/// queue-level tests set a callback before calling `loadSnapshot()` directly,
/// which production never does, so they cannot see a callback installed late.
@MainActor
final class PipelineControllerRestoreTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    /// Settings over a per-test `UserDefaults` suite, never `.standard`.
    private var settings: AppSettings!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = try makeTempDirectory(prefix: "PipelineControllerRestoreTests")
        let suite = "PipelineControllerRestoreTests-\(getpid())-\(UUID().uuidString)"
        settings = try AppSettings(
            defaults: XCTUnwrap(DefaultsSuite.open(suite)),
            defaultOutputDir: tmpDir.appendingPathComponent("output", isDirectory: true),
        )
        addTeardownBlock { DefaultsSuite.remove(suite) }
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try await super.tearDown()
    }

    /// A job left waiting for names, restored with auto-open off: no window
    /// opens, so the notification is the only prompt it gets, and it is raised
    /// from inside the restore.
    func testARebuildAnnouncesARestoredPendingJobWhenAutoOpenIsOff() throws {
        settings.autoOpenSpeakerNaming = false
        let job = try writePendingSnapshot(withNamingData: true)
        let notifier = RecordingNotifier()
        let pc = makeRestoringController(notifier: notifier)

        pc.rebuild()

        XCTAssertEqual(pc.queue.pendingSpeakerNamingJobs.map(\.id), [job.id], "test premise: the job is restored pending")
        XCTAssertEqual(notifier.calls.map(\.title), ["Name Speakers"])
    }

    /// A restored pending job whose naming data is gone is finished through
    /// the normal transition, which is what reports a finished meeting.
    func testARebuildReportsAJobTheRestoreFinishes() throws {
        let job = try writePendingSnapshot(withNamingData: false)
        let notifier = RecordingNotifier()
        let pc = makeRestoringController(notifier: notifier)

        pc.rebuild()

        XCTAssertEqual(pc.queue.jobs.first { $0.id == job.id }?.state, .done, "test premise: the restore finishes the job")
        XCTAssertEqual(notifier.calls.map(\.title), ["Transcript Saved"])
    }

    /// A controller that builds its queue from the snapshot in `tmpDir`, with
    /// the notifier the test reads.
    private func makeRestoringController(notifier: RecordingNotifier) -> PipelineController {
        let pc = PipelineController(
            settings: settings, notifier: notifier,
            queueEnvironment: IsolatedQueueEnvironment.make(logDir: tmpDir),
        )
        let engine = MockEngine()
        pc.activate { engine }
        return pc
    }

    /// A snapshot holding one job parked for speaker naming, as a quit leaves
    /// it, with or without its naming data in the controller's output folder.
    private func writePendingSnapshot(withNamingData: Bool) throws -> PipelineJob {
        var job = PipelineJob(
            meetingTitle: "Standup", appName: "Teams",
            mixPath: nil, appPath: nil, micPath: nil, micDelay: 0,
        )
        job.state = .speakerNamingPending
        job.namingSlug = "standup_pending"
        try JSONEncoder().encode([job]).write(to: tmpDir.appendingPathComponent(PipelineSnapshot.snapshotFilename))
        if withNamingData {
            let namingData = PipelineQueue.SpeakerNamingData(
                jobID: job.id, meetingTitle: "Standup", mapping: [:], speakingTimes: [:], embeddings: [:],
                audioPath: nil, segments: [], participants: [], isDualSource: false,
            )
            try SpeakerNamingStore(outputDir: settings.effectiveOutputDir).save(namingData, slug: "standup_pending")
        }
        return job
    }
}
