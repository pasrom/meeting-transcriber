import XCTest
@testable import MeetingTranscriber

@MainActor
final class PipelineQueueTests: XCTestCase {

    private var tmpDir: URL!
    private var queue: PipelineQueue!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline_queue_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        queue = PipelineQueue(logDir: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeJob(title: String = "Test Meeting") -> PipelineJob {
        PipelineJob(
            meetingTitle: title,
            appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0
        )
    }

    func testEnqueueAddsJob() {
        let job = makeJob()
        queue.enqueue(job)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].meetingTitle, "Test Meeting")
    }

    func testEnqueueMultipleJobs() {
        queue.enqueue(makeJob(title: "Meeting 1"))
        queue.enqueue(makeJob(title: "Meeting 2"))
        XCTAssertEqual(queue.jobs.count, 2)
    }

    func testSnapshotWrittenOnEnqueue() {
        queue.enqueue(makeJob())
        let snapshotPath = tmpDir.appendingPathComponent("pipeline_queue.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath.path))
    }

    func testSnapshotIsValidJSON() throws {
        queue.enqueue(makeJob(title: "Standup"))
        let snapshotPath = tmpDir.appendingPathComponent("pipeline_queue.json")
        let data = try Data(contentsOf: snapshotPath)
        let jobs = try JSONDecoder().decode([PipelineJob].self, from: data)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].meetingTitle, "Standup")
    }

    func testLogAppendedOnEnqueue() throws {
        queue.enqueue(makeJob())
        let logPath = tmpDir.appendingPathComponent("pipeline_log.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath.path))
        let content = try String(contentsOf: logPath, encoding: .utf8)
        XCTAssertTrue(content.contains("enqueued"))
    }

    func testActiveJobs() {
        var job1 = makeJob(title: "Active")
        job1.state = .transcribing
        queue.enqueue(job1)
        queue.enqueue(makeJob(title: "Waiting"))
        XCTAssertEqual(queue.activeJobs.count, 1)
        XCTAssertEqual(queue.activeJobs[0].meetingTitle, "Active")
    }

    func testPendingJobs() {
        queue.enqueue(makeJob(title: "Waiting 1"))
        queue.enqueue(makeJob(title: "Waiting 2"))
        XCTAssertEqual(queue.pendingJobs.count, 2)
    }

    func testRemoveCompletedJob() {
        var job = makeJob()
        job.state = .done
        queue.enqueue(job)
        XCTAssertEqual(queue.jobs.count, 1)
        queue.removeJob(id: job.id)
        XCTAssertEqual(queue.jobs.count, 0)
    }
}
