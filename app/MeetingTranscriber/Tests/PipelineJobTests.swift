@testable import MeetingTranscriber
import XCTest

final class PipelineJobTests: XCTestCase {
    func testInitialStateIsWaiting() {
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        XCTAssertEqual(job.state, .waiting)
        XCTAssertNil(job.error)
        XCTAssertTrue(job.warnings.isEmpty)
        XCTAssertNotNil(job.id)
    }

    func testJobIsCodable() throws {
        let job = PipelineJob(
            meetingTitle: "Sprint",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: URL(fileURLWithPath: "/tmp/app.wav"),
            micPath: URL(fileURLWithPath: "/tmp/mic.wav"),
            micDelay: 0.5,
        )
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(PipelineJob.self, from: data)
        XCTAssertEqual(decoded.id, job.id)
        XCTAssertEqual(decoded.meetingTitle, "Sprint")
        XCTAssertEqual(decoded.state, .waiting)
        XCTAssertEqual(decoded.micDelay, 0.5)
        XCTAssertTrue(decoded.warnings.isEmpty)
    }

    func testWarningsSurviveEncoding() throws {
        var job = PipelineJob(
            meetingTitle: "Retro",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.warnings = ["Diarization failed — speakers not identified", "Speaker naming skipped"]
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(PipelineJob.self, from: data)
        XCTAssertEqual(decoded.warnings, ["Diarization failed — speakers not identified", "Speaker naming skipped"])
    }

    func testTranscriptPathSurvivesEncoding() throws {
        var job = PipelineJob(
            meetingTitle: "Transcript Test",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        job.transcriptPath = URL(fileURLWithPath: "/tmp/transcript.txt")
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(PipelineJob.self, from: data)
        XCTAssertEqual(decoded.transcriptPath, job.transcriptPath)
    }

    func testJobStateIsCodable() throws {
        for state in [
            JobState.waiting,
            .transcribing,
            .diarizing,
            .generatingProtocol,
            .done,
            .error,
        ] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(JobState.self, from: data)
            XCTAssertEqual(decoded, state)
        }
    }

    func test_shortID_isEightLowercaseHexChars() {
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        XCTAssertEqual(job.shortID.count, 8)
        XCTAssertTrue(job.shortID.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func test_shortID_isStableForSameJob() {
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        XCTAssertEqual(job.shortID, job.shortID)
    }

    func test_shortID_differsAcrossJobs() {
        let a = PipelineJob(
            meetingTitle: "A", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        let b = PipelineJob(
            meetingTitle: "B", appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
        XCTAssertNotEqual(a.shortID, b.shortID)
    }

    func test_shortID_staticHelperMatchesInstanceProperty() {
        let job = PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        XCTAssertEqual(PipelineJob.shortID(for: job.id), job.shortID)
    }

    func testJobStateRawValues() {
        XCTAssertEqual(JobState.waiting.rawValue, "waiting")
        XCTAssertEqual(JobState.transcribing.rawValue, "transcribing")
        XCTAssertEqual(JobState.diarizing.rawValue, "diarizing")
        XCTAssertEqual(JobState.generatingProtocol.rawValue, "generatingProtocol")
        XCTAssertEqual(JobState.done.rawValue, "done")
        XCTAssertEqual(JobState.error.rawValue, "error")
    }

    // MARK: - Sidecar folders

    // The folder list is asserted through `sidecarOutputDirs`, which is what
    // every reader uses. The decode test is the exception and names the stored
    // key on purpose, since dropping that key is what it checks survives.

    /// A job that writes sidecars under a second folder has to keep the first:
    /// the files an earlier write left there are still only reachable through
    /// the job, and nothing sweeps an output folder for orphans.
    func testRecordingASecondSidecarFolderKeepsTheFirst() {
        var job = Self.makeJob()
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/first"))
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/second"))

        XCTAssertEqual(job.sidecarOutputDir?.path, "/tmp/second")
        XCTAssertEqual(job.sidecarOutputDirs.map(\.path), ["/tmp/first", "/tmp/second"])
    }

    /// Both writers record on every run, and most runs record the same folder
    /// twice. Identity is by standardized path, so a differently spelled form
    /// of the same folder is not carried as a second one either.
    func testRecordingTheSameSidecarFolderTwiceCarriesItOnce() {
        var job = Self.makeJob()
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/out"))
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/out"))
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/./out"))

        XCTAssertEqual(job.sidecarOutputDirs.map(\.path), ["/tmp/out"])
    }

    /// Moving back to a folder already recorded leaves one entry per folder,
    /// with the one just written current. Otherwise a user switching back and
    /// forth would grow the list on every run.
    func testRecordingAFolderAgainMakesItCurrentWithoutDuplicatingIt() {
        var job = Self.makeJob()
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/a"))
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/b"))
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/a"))

        XCTAssertEqual(job.sidecarOutputDir?.path, "/tmp/a")
        XCTAssertEqual(job.sidecarOutputDirs.map(\.path), ["/tmp/b", "/tmp/a"])
    }

    /// A decoded state can hold the current folder in the earlier list, which
    /// this writer never produces. Recording the next folder then has to move
    /// the one it replaces to the newest end of the list rather than leaving it
    /// where it was, or the read order claims an older folder was written last
    /// and a restore takes its stale naming data over the current one.
    func testRecordingAFolderMovesTheReplacedOneToTheNewestEnd() throws {
        var fields = try Self.encodedFields(of: Self.makeJob())
        fields["previousSidecarOutputDirs"] = ["file:///tmp/b/", "file:///tmp/a/"]
        fields["sidecarOutputDir"] = "file:///tmp/b/"
        let encoded = try JSONSerialization.data(withJSONObject: fields)
        var job = try JSONDecoder().decode(PipelineJob.self, from: encoded)
        XCTAssertEqual(job.sidecarOutputDirs.map(\.path), ["/tmp/b", "/tmp/a", "/tmp/b"])

        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/c"))

        XCTAssertEqual(job.sidecarOutputDirs.map(\.path), ["/tmp/a", "/tmp/b", "/tmp/c"])
    }

    /// A snapshot written before the field existed has to decode, or a restart
    /// after the update drops every job the user had queued.
    func testAJobDecodesWithoutThePreviousSidecarFoldersKey() throws {
        var job = Self.makeJob()
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/first"))
        job.recordSidecarOutputDir(URL(fileURLWithPath: "/tmp/second"))
        var fields = try Self.encodedFields(of: job)
        // Present to begin with, so the removal below is what the decode is
        // then asked to survive.
        XCTAssertNotNil(fields.removeValue(forKey: "previousSidecarOutputDirs"))
        let older = try JSONSerialization.data(withJSONObject: fields)

        let decoded = try JSONDecoder().decode(PipelineJob.self, from: older)

        XCTAssertEqual(decoded.sidecarOutputDirs.map(\.path), ["/tmp/second"])
    }

    /// A job's encoded form as a mutable dictionary, so a test can produce a
    /// state no writer reaches and decode it back.
    private static func encodedFields(of job: PipelineJob) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(job)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }

    private static func makeJob() -> PipelineJob {
        PipelineJob(
            meetingTitle: "Standup", appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil, micPath: nil, micDelay: 0,
        )
    }
}
