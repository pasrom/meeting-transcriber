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

    func testJobStateRawValues() {
        XCTAssertEqual(JobState.waiting.rawValue, "waiting")
        XCTAssertEqual(JobState.transcribing.rawValue, "transcribing")
        XCTAssertEqual(JobState.diarizing.rawValue, "diarizing")
        XCTAssertEqual(JobState.generatingProtocol.rawValue, "generatingProtocol")
        XCTAssertEqual(JobState.done.rawValue, "done")
        XCTAssertEqual(JobState.error.rawValue, "error")
    }
}
