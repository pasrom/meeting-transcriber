@testable import MeetingTranscriber
import XCTest

/// Removing a job has to clean up the files that belong to it, and those sit in
/// the folder the job recorded rather than the one the queue currently writes
/// to. The two differ after the user picks another output folder, which is
/// exactly when a queue built against the new folder still holds a job whose
/// sidecars were written under the old one.
@MainActor
final class RemoveJobSidecarFolderTests: XCTestCase {
    func testRemovingAJobCleansUpUnderTheFolderItsSidecarsWereWrittenTo() throws {
        let recorded = try makeTempDirectory(prefix: "RemoveJobRecorded")
        let current = try makeTempDirectory(prefix: "RemoveJobCurrent")
        let logDir = try makeTempDirectory(prefix: "RemoveJobLog")

        // Every sidecar the cleanup owns, including the `_naming.json` that the
        // same call deletes, under the recorded folder.
        let recordings = recorded.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let sidecars = try SidecarFixture.write(slug: "meeting", in: recordings)

        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: current,
            logDir: logDir,
        )
        var job = PipelineJob(
            meetingTitle: "Meeting", appName: "Teams",
            mixPath: recordings.appendingPathComponent("meeting_mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.namingSlug = "meeting"
        job.sidecarOutputDir = recorded
        job.state = .speakerNamingPending
        queue.insertJobForTesting(job)

        queue.removeJob(id: job.id)

        // Named assertion rather than a count: it reports which file stayed.
        assertSidecars(sidecars, exist: false)
    }

    /// Cancelling is the one path that leaks the files for good: it removes the
    /// job at once, so no reaper follows to clean up after it. It passes no
    /// folder, so this drives the resolution through a production call rather
    /// than the parameter default on its own.
    ///
    /// `.diarizing`, because that is the reachable state: Cancel is offered for
    /// a running job, not for one parked for naming, which gets Dismiss
    /// instead. A parked job's sidecars are nonetheless what gets cancelled
    /// here, via a late re-diarization started from the naming dialog, which
    /// puts an already-named job back into `.diarizing`.
    func testCancellingAJobCleansUpUnderTheFolderItRecorded() throws {
        let recorded = try makeTempDirectory(prefix: "CancelRecorded")
        let current = try makeTempDirectory(prefix: "CancelCurrent")
        let logDir = try makeTempDirectory(prefix: "CancelLog")
        let recordings = recorded.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let sidecars = try SidecarFixture.write(slug: "meeting", in: recordings)

        let queue = PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: current,
            logDir: logDir,
        )
        var job = PipelineJob(
            meetingTitle: "Meeting", appName: "Teams",
            mixPath: recordings.appendingPathComponent("meeting_mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        job.namingSlug = "meeting"
        job.sidecarOutputDir = recorded
        job.state = .diarizing
        queue.insertJobForTesting(job)

        queue.cancelJob(id: job.id)

        assertSidecars(sidecars, exist: false)
    }
}
