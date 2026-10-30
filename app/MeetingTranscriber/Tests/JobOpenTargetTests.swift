@testable import MeetingTranscriber
import XCTest

final class JobOpenTargetTests: XCTestCase {
    func testNotionWinsWhenEnabledAndAPageExists() throws {
        var job = makeJob()
        job.protocolPath = URL(fileURLWithPath: "/tmp/protocol.md")
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )
        job.finishNotionExport(succeeded: true)

        let target = JobOpenTarget.resolve(for: job, preferNotion: true)

        XCTAssertEqual(target, try .notion(XCTUnwrap(URL(string: "https://www.notion.so/page-1"))))
        XCTAssertEqual(target?.jobActionLabel, "Open in Notion")
        XCTAssertEqual(target?.lastProtocolLabel, "Open Last Notes in Notion")
    }

    func testLocalFileWinsWhenNotionIsDisabled() {
        var job = makeJob()
        job.protocolPath = URL(fileURLWithPath: "/tmp/protocol.md")
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )

        let target = JobOpenTarget.resolve(for: job, preferNotion: false)

        XCTAssertEqual(target, .file(URL(fileURLWithPath: "/tmp/protocol.md")))
        XCTAssertEqual(target?.jobActionLabel, "Open")
    }

    func testNotionPageIsUsedWhenNoLocalFileExists() throws {
        var job = makeJob()
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )
        job.finishNotionExport(succeeded: true)

        let target = JobOpenTarget.resolve(for: job, preferNotion: false)

        XCTAssertEqual(target, try .notion(XCTUnwrap(URL(string: "https://www.notion.so/page-1"))))
    }

    func testPartialNotionPageUsesLocalBackupRegardlessOfPreference() {
        var job = makeJob()
        job.protocolPath = URL(fileURLWithPath: "/tmp/protocol.md")
        job.beginNotionExport(speakerNames: [])
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )

        XCTAssertEqual(
            JobOpenTarget.resolve(for: job, preferNotion: true),
            .file(URL(fileURLWithPath: "/tmp/protocol.md")),
        )
        job.finishNotionExport(succeeded: false)
        XCTAssertEqual(
            JobOpenTarget.resolve(for: job, preferNotion: false),
            .file(URL(fileURLWithPath: "/tmp/protocol.md")),
        )
    }

    func testPartialNotionPageWithoutLocalBackupHasNoOpenTarget() {
        var job = makeJob()
        job.beginNotionExport(speakerNames: [])
        job.recordNotionPage(
            NotionPageResult(pageID: "page-1", url: "https://www.notion.so/page-1"),
            databaseID: "database-1",
        )

        XCTAssertNil(JobOpenTarget.resolve(for: job, preferNotion: true))
    }

    func testTranscriptIsTheFallbackWhenNoProtocolWasSaved() {
        var job = makeJob()
        job.transcriptPath = URL(fileURLWithPath: "/tmp/transcript.txt")

        let target = JobOpenTarget.resolve(for: job, preferNotion: true)

        XCTAssertEqual(target, .file(URL(fileURLWithPath: "/tmp/transcript.txt")))
    }

    func testNoTargetWithoutAFileOrPage() {
        XCTAssertNil(JobOpenTarget.resolve(for: makeJob(), preferNotion: true))
        XCTAssertNil(JobOpenTarget.resolve(for: nil, preferNotion: true))
    }

    private func makeJob() -> PipelineJob {
        PipelineJob(
            meetingTitle: "Standup",
            appName: "Teams",
            mixPath: nil,
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
    }
}
