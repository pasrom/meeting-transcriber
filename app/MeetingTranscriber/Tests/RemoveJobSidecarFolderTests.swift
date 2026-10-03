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

        // One sidecar per suffix the cleanup knows, under the recorded folder.
        let recordings = recorded.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let sidecars = SpeakerNamingStore.sidecarSuffixes.map {
            recordings.appendingPathComponent("meeting\($0)")
        }
        for url in sidecars { try Data("sidecar".utf8).write(to: url) }

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

        let left = sidecars.filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertTrue(
            left.isEmpty,
            "\(left.count) sidecar(s) stayed behind: the cleanup ran against the queue's current folder "
                + "instead of the one the job recorded, and nothing else ever sweeps them up",
        )
    }
}
