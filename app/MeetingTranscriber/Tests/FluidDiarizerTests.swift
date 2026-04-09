@testable import MeetingTranscriber
import XCTest

final class FluidDiarizerTests: XCTestCase {
    func testIsAlwaysAvailable() {
        let diarizer = FluidDiarizer()
        XCTAssertTrue(diarizer.isAvailable)
    }

    // MARK: - normalizeSpeakerId

    func testNormalizeSpeakerIdStandard() {
        XCTAssertEqual(FluidDiarizer.normalizeSpeakerId("Speaker 0"), "SPEAKER_0")
    }

    func testNormalizeSpeakerIdMultipleDigits() {
        XCTAssertEqual(FluidDiarizer.normalizeSpeakerId("Speaker 12"), "SPEAKER_12")
    }

    func testNormalizeSpeakerIdAlreadyNormalized() {
        XCTAssertEqual(FluidDiarizer.normalizeSpeakerId("SPEAKER_0"), "SPEAKER_0")
    }

    func testNormalizeSpeakerIdNoMatch() {
        XCTAssertEqual(FluidDiarizer.normalizeSpeakerId("Custom Name"), "Custom Name")
    }

    // MARK: - buildResult

    func testBuildResultSortsByStartTime() {
        let segments: [DiarizationResult.Segment] = [
            .init(start: 5, end: 10, speaker: "SPEAKER_0"),
            .init(start: 0, end: 5, speaker: "SPEAKER_1"),
        ]
        let result = FluidDiarizer.buildResult(segments: segments, speakerDatabase: nil)
        XCTAssertEqual(result.segments[0].start, 0)
        XCTAssertEqual(result.segments[1].start, 5)
    }

    func testBuildResultComputesSpeakingTimes() {
        let segments: [DiarizationResult.Segment] = [
            .init(start: 0, end: 5, speaker: "SPEAKER_0"),
            .init(start: 5, end: 10, speaker: "SPEAKER_1"),
            .init(start: 10, end: 20, speaker: "SPEAKER_0"),
        ]
        let result = FluidDiarizer.buildResult(segments: segments, speakerDatabase: nil)
        XCTAssertEqual(result.speakingTimes["SPEAKER_0"], 15.0)
        XCTAssertEqual(result.speakingTimes["SPEAKER_1"], 5.0)
    }

    func testBuildResultEmptySegments() {
        let result = FluidDiarizer.buildResult(segments: [], speakerDatabase: nil)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(result.speakingTimes.isEmpty)
    }

    func testBuildResultNilEmbeddings() {
        let result = FluidDiarizer.buildResult(
            segments: [.init(start: 0, end: 5, speaker: "SPEAKER_0")],
            speakerDatabase: nil,
        )
        XCTAssertNil(result.embeddings)
    }

    // MARK: - Crash Recovery (retry with auto-detect)

    private static let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")

    fileprivate static func makeResult(speaker: String = "SPEAKER_0") -> DiarizationResult {
        DiarizationResult(
            segments: [.init(start: 0, end: 5, speaker: speaker)],
            speakingTimes: [speaker: 5],
            autoNames: [:],
            embeddings: nil,
        )
    }

    func testRetryWithAutoDetectOnFailure() async throws {
        var mock = MockOfflineProcessor()
        var callCount = 0
        mock.onProcess = { _ in
            callCount += 1
            if callCount == 1 {
                throw NSError(domain: "FluidAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "KMeans failed"])
            }
            return Self.makeResult()
        }
        let diarizer = FluidDiarizer(mode: .offline, offlineProcessor: mock)

        let result = try await diarizer.run(
            audioPath: Self.dummyURL, numSpeakers: 5, meetingTitle: "Test",
        )
        XCTAssertEqual(callCount, 2, "Should retry once after failure")
        XCTAssertEqual(result.segments.count, 1)
    }

    func testNoRetryWithoutNumSpeakers() async {
        var mock = MockOfflineProcessor()
        mock.onProcess = { _ in
            throw NSError(domain: "FluidAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "KMeans failed"])
        }
        let diarizer = FluidDiarizer(mode: .offline, offlineProcessor: mock)

        do {
            _ = try await diarizer.run(
                audioPath: Self.dummyURL, numSpeakers: nil, meetingTitle: "Test",
            )
            XCTFail("Expected error to propagate when numSpeakers is nil")
        } catch {
            // Expected — no retry when numSpeakers is nil
        }
    }

    func testNoRetryOnSuccess() async throws {
        var mock = MockOfflineProcessor()
        var callCount = 0
        mock.onProcess = { _ in
            callCount += 1
            return Self.makeResult()
        }
        let diarizer = FluidDiarizer(mode: .offline, offlineProcessor: mock)

        _ = try await diarizer.run(
            audioPath: Self.dummyURL, numSpeakers: 3, meetingTitle: "Test",
        )
        XCTAssertEqual(callCount, 1, "Should not retry on success")
    }

    func testErrorPropagatesOnRetryFailure() async {
        var mock = MockOfflineProcessor()
        mock.onProcess = { _ in
            throw NSError(domain: "FluidAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Always fails"])
        }
        let diarizer = FluidDiarizer(mode: .offline, offlineProcessor: mock)

        do {
            _ = try await diarizer.run(
                audioPath: Self.dummyURL, numSpeakers: 5, meetingTitle: "Test",
            )
            XCTFail("Expected error when both attempts fail")
        } catch {
            // Expected — retry also failed, error propagates
        }
    }
}

// MARK: - Mock

private struct MockOfflineProcessor: OfflineDiarizationProcessing {
    var onProcess: ((URL) async throws -> DiarizationResult)?

    // swiftlint:disable:next async_without_await unneeded_throws_rethrows
    mutating func prepare(numSpeakers _: Int?) async throws {}

    func process(audioPath: URL) async throws -> DiarizationResult {
        guard let onProcess else {
            return FluidDiarizerTests.makeResult()
        }
        return try await onProcess(audioPath)
    }
}
