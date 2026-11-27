@testable import MeetingTranscriber
import XCTest

@MainActor
final class CloudDroppedTrackLogTests: XCTestCase {
    private final class RefusedMicEngine: MockEngine {
        override func transcribeSegments(audioPath: URL) throws -> [TimestampedSegment] {
            if audioPath.lastPathComponent == "mic_16k.wav" {
                throw CloudTranscriptionError.httpError(status: 413, body: "private vocabulary", param: "private parameter")
            }
            return [TimestampedSegment(start: 0, end: 0.5, text: "far end")]
        }
    }

    func testPartialSuccessLogsOnlyTrackStatusAndAllowlistedParamPublicly() async throws {
        let dir = try makeTempDirectory(prefix: "cloud_dropped_track")
        let queue = PipelineQueue(
            engine: RefusedMicEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: dir, logDir: dir, stagingDir: dir.appendingPathComponent("staging"),
            diarizeEnabled: false,
        )
        var publicLines: [String] = []
        var privateLines: [String] = []
        queue.logDroppedTrack = { summary, detail in
            publicLines.append(summary)
            privateLines.append(detail)
        }
        let app = dir.appendingPathComponent("meeting_app.wav")
        let mic = dir.appendingPathComponent("meeting_mic.wav")
        for url in [app, mic] {
            try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: 16000), sampleRate: 16000, url: url)
        }
        queue.enqueue(PipelineJob(meetingTitle: "Meeting", appName: "File", mixPath: nil, appPath: app, micPath: mic, micDelay: 0))
        await queue.processNext()
        await waitFor(queue.jobs.first?.state.isTerminal ?? false, timeout: .seconds(10))

        let job = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(publicLines.map { $0.drop { $0 != " " }.dropFirst() }, ["dropped_track=mic http status=413 param=other"])
        XCTAssertTrue(publicLines.allSatisfy { $0.hasPrefix("[") }, "the line lost its job ID")
        XCTAssertEqual(privateLines, job.warnings)
        XCTAssertTrue(privateLines.joined().contains("private vocabulary"))
    }
}
