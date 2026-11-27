@testable import MeetingTranscriber
import XCTest

/// Which slots of a restored job are pointed at the output folder: only a
/// staging path that is gone, and only when the relocated file of this job's
/// own stem is there. Pure, with the file system replaced by a set.
final class RelocatedAudioRepointTests: XCTestCase {
    private let staging = URL(fileURLWithPath: "/repoint-test/staging")
    private let recordings = URL(fileURLWithPath: "/repoint-test/Output/recordings")

    private func makeJob(app: Bool = true, mic: Bool = true, in dir: URL? = nil) throws -> PipelineJob {
        let dir = dir ?? staging
        var job = PipelineJob(
            meetingTitle: "Weekly Sync", appName: "Teams",
            mixPath: dir.appendingPathComponent("20260304_091500_mix.wav"),
            appPath: app ? dir.appendingPathComponent("20260304_091500_app.wav") : nil,
            micPath: mic ? dir.appendingPathComponent("20260304_091500_mic.wav") : nil,
            micDelay: 0,
        )
        job.meetingStartTime = try localDate(2026, 3, 4, 9, 15)
        return job
    }

    /// Stage 3's name for the job's file, written out rather than computed, so
    /// the repoint is pinned to the stem stage 3 really uses.
    private func relocated(_ job: PipelineJob, _ suffix: String) -> URL {
        recordings.appendingPathComponent("20260304_0915_weekly_sync_\(job.shortID)\(suffix)")
    }

    private func plan(_ job: PipelineJob, existing: Set<URL>) -> RelocatedAudioPaths? {
        RelocatedAudioRepoint.plan(for: job, stagingDir: staging, recordingsDir: recordings) { existing.contains($0) }
    }

    func testAGoneStagingMixIsRepointedToTheRelocatedFile() throws {
        let job = try makeJob(app: false, mic: false)
        let destination = relocated(job, RecordingFileSuffix.mix)

        let paths = try XCTUnwrap(plan(job, existing: [destination]))

        XCTAssertEqual(paths.mix, destination)
        XCTAssertNil(paths.app)
        XCTAssertNil(paths.mic)
    }

    /// Order of the moves is mix, app, mic: a kill after the second leaves two
    /// slots to repoint, and repointing the mix alone would run the job with
    /// its app track missing.
    func testEveryGoneTrackWithARelocatedFileIsRepointed() throws {
        let job = try makeJob()
        let mix = relocated(job, RecordingFileSuffix.mix)
        let app = relocated(job, RecordingFileSuffix.app)
        let stagedMic = try XCTUnwrap(job.micPath)

        let paths = try XCTUnwrap(plan(job, existing: [mix, app, stagedMic]))

        XCTAssertEqual(paths.mix, mix)
        XCTAssertEqual(paths.app, app)
        XCTAssertEqual(paths.mic, stagedMic, "a track still in staging is moved by the run itself")
    }

    func testAStagingTrackThatStillExistsIsLeftAlone() throws {
        let job = try makeJob()
        let staged = try [XCTUnwrap(job.mixPath), XCTUnwrap(job.appPath), XCTUnwrap(job.micPath)]
        let destinations = RecordingFileSuffix.all
            .map { relocated(job, $0) }

        XCTAssertNil(plan(job, existing: Set(staged + destinations)))
    }

    func testAGoneTrackWithNoRelocatedFileIsNotRepointed() throws {
        let job = try makeJob()

        XCTAssertNil(plan(job, existing: []), "a job whose audio is gone everywhere is left to the discard rule")
    }

    func testAnImportedPathIsNeverRepointed() throws {
        let job = try makeJob(in: URL(fileURLWithPath: "/repoint-test/Users-folder"))
        let destinations = RecordingFileSuffix.all
            .map { relocated(job, $0) }

        XCTAssertNil(plan(job, existing: Set(destinations)), "a file the user picked is never the app's to move")
    }

    func testAPathAlreadyInTheOutputFolderIsNeverRepointed() throws {
        let job = try makeJob(in: recordings)

        XCTAssertNil(plan(job, existing: [relocated(job, RecordingFileSuffix.mix)]))
    }

    /// The run records its stem on the job before the move. The stem rebuilt
    /// from the start time can differ from it (the time zone changed between
    /// the run and the restore), so the recorded one is tried first.
    func testTheRecordedStemIsTriedBeforeTheRebuiltOne() throws {
        var job = try makeJob(app: false, mic: false)
        job.namingSlug = "20260304_1015_weekly_sync_\(job.shortID)"
        let recorded = recordings.appendingPathComponent("20260304_1015_weekly_sync_\(job.shortID)_mix.wav")
        let rebuilt = relocated(job, RecordingFileSuffix.mix)

        XCTAssertEqual(plan(job, existing: [recorded, rebuilt])?.mix, recorded, "the recorded stem comes first")
        XCTAssertEqual(plan(job, existing: [rebuilt])?.mix, rebuilt, "the rebuilt one when nothing is under it")
    }

    /// An AI-title rename can leave `namingSlug` as the bare title. A file
    /// under it is another recording's or the renamed one's, never the file
    /// of a slot that still names staging.
    func testABareTitleStemIsNeverTaken() throws {
        var job = try makeJob(app: false, mic: false)
        job.namingSlug = "weekly_sync"

        XCTAssertNil(plan(job, existing: [recordings.appendingPathComponent("weekly_sync_mix.wav")]))
    }

    /// A restored job that already names the output folder (a finished job
    /// held for a retry, one waiting for names) is the usual case at launch,
    /// and the output folder can be a network mount: nothing is stat'ed.
    func testASlotOutsideStagingIsNeverStatted() throws {
        let job = try makeJob(in: recordings)
        var stats = 0

        let paths = RelocatedAudioRepoint.plan(for: job, stagingDir: staging, recordingsDir: recordings) { _ in
            stats += 1
            return true
        }

        XCTAssertNil(paths)
        XCTAssertEqual(stats, 0)
    }

    /// The staging folder given through a link still matches the paths the
    /// recorder wrote under the folder it points to.
    func testAStagingFolderGivenThroughALinkIsStillStaging() throws {
        let root = try makeTempDirectory(prefix: "repoint_link")
        let realStaging = root.appendingPathComponent("staging-real")
        let linkedStaging = root.appendingPathComponent("staging-link")
        try FileManager.default.createDirectory(at: realStaging, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedStaging, withDestinationURL: realStaging)
        let job = try makeJob(app: false, mic: false, in: realStaging.resolvingSymlinksInPath())
        let destination = relocated(job, RecordingFileSuffix.mix)

        let paths = RelocatedAudioRepoint.plan(for: job, stagingDir: linkedStaging, recordingsDir: recordings) { url in
            url == destination
        }

        XCTAssertEqual(paths?.mix, destination)
    }

    /// Another job's relocated files share the staging path but not the stem,
    /// which carries the job's own short ID.
    func testOnlyTheJobsOwnStemIsTaken() throws {
        let owner = try makeJob()
        let duplicate = try makeJob()
        let ownersFiles = RecordingFileSuffix.all
            .map { relocated(owner, $0) }

        XCTAssertNil(plan(duplicate, existing: Set(ownersFiles)))
        XCTAssertNotNil(plan(owner, existing: Set(ownersFiles)))
    }
}
