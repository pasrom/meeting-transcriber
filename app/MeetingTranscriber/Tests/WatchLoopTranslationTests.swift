@testable import MeetingTranscriber
import XCTest

@MainActor
final class WatchLoopTranslationTests: XCTestCase {
    func testManualRecordingKeepsStartConfigurationThroughEnqueue() async throws {
        let dir = try makeTempDirectory(prefix: "manual-translation")
        let queue = PipelineQueue(logDir: dir)
        let recorder = makeMockRecorder()
        var configuration = translationConfiguration()
        let loop = WatchLoop(
            recorderFactory: { recorder }, pipelineQueue: queue,
            transcriptionConfiguration: { configuration }, // swiftlint:disable:this trailing_closure
        )
        loop.permissionChecker = { HealthCheckResult(screenRecording: .healthy, microphone: .healthy) }
        try await loop.startMicrophoneRecording()
        configuration.whisper?.outputMode = .original
        loop.stopManualRecording()
        XCTAssertEqual(queue.jobs.first?.transcriptionConfiguration, translationConfiguration())
    }

    func testAutomaticRecordingKeepsStartConfigurationThroughEnqueue() async throws {
        let dir = try makeTempDirectory(prefix: "auto-translation")
        let queue = PipelineQueue(logDir: dir)
        let recorder = makeMockRecorder()
        var configuration = translationConfiguration()
        let loop = WatchLoop(
            detector: ImmediatelyInactiveDetector(),
            recorderFactory: {
                // Represents a Settings change after recording setup began.
                configuration.whisper?.outputMode = .original
                return recorder
            },
            pipelineQueue: queue, pollInterval: 0.01, endGracePeriod: 0.01,
            transcriptionConfiguration: { configuration }, // swiftlint:disable:this trailing_closure
        )
        let meeting = DetectedMeeting(
            pattern: .teams, windowTitle: "Meeting", ownerName: "Microsoft Teams", windowPID: 9999,
        )
        try await loop.handleMeeting(meeting)
        XCTAssertEqual(queue.jobs.first?.transcriptionConfiguration, translationConfiguration())
    }

    private func translationConfiguration() -> TranscriptionConfiguration {
        .init(whisper: .init(modelVariant: "openai_whisper-small", language: nil, outputMode: .translateToEnglish))
    }
}
