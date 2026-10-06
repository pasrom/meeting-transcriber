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
        let test = try makeCase("RemoveJob", state: .speakerNamingPending)

        test.queue.removeJob(id: test.job.id)

        // Named assertion rather than a count: it reports which file stayed.
        assertSidecars(test.sidecars, exist: false)
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
        let test = try makeCase("Cancel", state: .diarizing)

        test.queue.cancelJob(id: test.job.id)

        assertSidecars(test.sidecars, exist: false)
    }

    /// A job can write sidecars under two folders in its lifetime, and removing
    /// it has to clean up both.
    ///
    /// Reachable without any folder change mid-run: a headless run that keeps
    /// its `_naming.json` and is interrupted during protocol generation is
    /// restored as a full run, so after the user repoints the output folder it
    /// saves naming data a second time, now under the new folder, while the
    /// first run's audio sidecars still sit under the old one. Recording only
    /// one of the two folders strands the other one's files for good: nothing
    /// sweeps an output folder for orphans, and removing the job takes away the
    /// snapshot entry that would have named them.
    func testRemovingAJobCleansUpEveryFolderItWroteSidecarsTo() throws {
        let test = try makeCase("TwoFolder", state: .speakerNamingPending)
        let underCurrent = try SidecarFixture.write(
            slug: Self.slug, in: makeRecordingsDir(in: test.current),
        )

        // The production call that records a folder: the second run has just
        // saved its naming data under the folder this queue writes to.
        test.queue.setNamingMetadata(jobID: test.job.id, slug: Self.slug, usedDiarizerMode: nil)
        test.queue.removeJob(id: test.job.id)

        assertSidecars(test.sidecars + underCurrent, exist: false)
    }

    /// The same two-folder case through the path that passes no folder at all,
    /// so the resolution runs over the job the delegate hands back rather than
    /// over an argument. Cancel is the path that leaks for good, and a
    /// single-folder resolution there stays green in every other test.
    func testCancellingAJobCleansUpEveryFolderItWroteSidecarsTo() throws {
        let test = try makeCase("TwoFolderCancel", state: .diarizing)
        let underCurrent = try SidecarFixture.write(
            slug: Self.slug, in: makeRecordingsDir(in: test.current),
        )

        test.queue.setNamingMetadata(jobID: test.job.id, slug: Self.slug, usedDiarizerMode: nil)
        test.queue.cancelJob(id: test.job.id)

        assertSidecars(test.sidecars + underCurrent, exist: false)
    }

    // MARK: - Arrangement

    private static let slug = "meeting"

    private struct Case {
        let queue: PipelineQueue
        let job: PipelineJob
        /// The folder the queue writes to, which is not the one the job
        /// recorded.
        let current: URL
        /// The files written under the recorded folder.
        let sidecars: [URL]
    }

    /// A queue writing to a fresh folder, holding one job that recorded a
    /// different one, with that job's full set of sidecars on disk under the
    /// recorded folder.
    ///
    /// Shared because the three tests here differ only in how they remove the
    /// job: copying the arrangement instead is what left the `_naming.json`
    /// unchecked once already, which is why `SidecarFixture` exists.
    private func makeCase(_ prefix: String, state: JobState) throws -> Case {
        let recorded = try makeTempDirectory(prefix: "\(prefix)Recorded")
        let current = try makeTempDirectory(prefix: "\(prefix)Current")
        let logDir = try makeTempDirectory(prefix: "\(prefix)Log")
        // Every sidecar the cleanup owns, including the `_naming.json` that the
        // same call deletes.
        let recordings = try makeRecordingsDir(in: recorded)
        let sidecars = try SidecarFixture.write(slug: Self.slug, in: recordings)

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
        job.namingSlug = Self.slug
        job.recordSidecarOutputDir(recorded)
        job.state = state
        queue.insertJobForTesting(job)
        return Case(queue: queue, job: job, current: current, sidecars: sidecars)
    }
}
