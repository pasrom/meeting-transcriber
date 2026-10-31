import enum FluidAudio.ASRError
@testable import MeetingTranscriber
import enum WhisperKit.WhisperError
import XCTest

/// The decisions behind keeping one track of a dual-source job: which failures
/// count as the file's (`TranscriptionFailureScope`) and what a pair of passes
/// leaves (`DualTrackTranscription.resolve`). The pipeline wiring is covered
/// in `EmptyTrackSurvivesTests`.
final class DualTrackTranscriptionTests: XCTestCase {
    private let fileFailure = ASRError.invalidAudioData
    private let far = [TimestampedSegment(start: 0, end: 1, text: "far")]
    private let near = [TimestampedSegment(start: 1, end: 2, text: "near")]

    // MARK: - Failure scope

    func testReadingTheFileBelongsToTheFile() {
        let fileScoped: [any Error] = [
            ASRError.invalidAudioData,
            ASRError.fileAccessFailed(URL(fileURLWithPath: "/x"), CocoaError(.fileReadUnknown)),
            WhisperError.loadAudioFailed("x"),
        ]
        for error in fileScoped {
            XCTAssertEqual(TranscriptionFailureScope.of(error), .file, "\(error)")
        }
    }

    /// Decode-time failures included: both libraries throw them for model
    /// wiring (tensor shapes, missing outputs), not for the audio.
    func testModelAndDecodeFailuresAndUnknownErrorsBelongToTheEngine() {
        let engineScoped: [any Error] = [
            ASRError.processingFailed("Joint decision returned unexpected tensor shapes"),
            WhisperError.decodingFailed("x"),
            WhisperError.decodingLogitsFailed("x"),
            WhisperError.segmentingFailed("x"),
            WhisperError.audioProcessingFailed("AudioEncoder input must be MLMultiArray"),
            TranscriptionError.modelNotLoaded(reason: "download failed"),
            ASRError.modelLoadFailed,
            ASRError.modelCompilationFailed,
            ASRError.notInitialized,
            WhisperError.modelsUnavailable("x"),
            WhisperError.tokenizerUnavailable("x"),
            NSError(domain: "unknown", code: 1),
        ]
        for error in engineScoped {
            XCTAssertEqual(TranscriptionFailureScope.of(error), .engine, "\(error)")
        }
    }

    // MARK: - Resolve

    func testBothSucceededKeepsBothAndTheVerdict() throws {
        let kept = try DualTrackTranscription.resolve(app: .success(far), mic: .success(near), viability: .both)

        XCTAssertEqual(kept.app.map(\.text), ["far"])
        XCTAssertEqual(kept.mic.map(\.text), ["near"])
        XCTAssertEqual(kept.viability, .both)
        XCTAssertTrue(kept.warnings.isEmpty)
    }

    func testAFailedMicTrackIsDroppedAndDowngradesTheVerdict() throws {
        let kept = try DualTrackTranscription.resolve(app: .success(far), mic: .failure(fileFailure), viability: .both)

        XCTAssertEqual(kept.app.map(\.text), ["far"])
        XCTAssertTrue(kept.mic.isEmpty)
        XCTAssertEqual(kept.viability, .appOnly)
        XCTAssertEqual(kept.warnings.count, 1)
        XCTAssertTrue(kept.warnings[0].contains("microphone track could not be transcribed"))
        XCTAssertTrue(kept.warnings[0].contains(fileFailure.localizedDescription))
    }

    func testAFailedAppTrackIsDroppedAndDowngradesTheVerdict() throws {
        let kept = try DualTrackTranscription.resolve(app: .failure(fileFailure), mic: .success(near), viability: .both)

        XCTAssertEqual(kept.viability, .micOnly)
        XCTAssertEqual(kept.mic.map(\.text), ["near"])
    }

    /// Nothing transcribed next to a failure: the failure is the explanation,
    /// not "Empty transcript".
    func testAnEmptySuccessDoesNotHideTheFailureNextToIt() {
        XCTAssertThrowsError(
            try DualTrackTranscription.resolve(app: .failure(fileFailure), mic: .success([]), viability: .both),
        ) { error in
            XCTAssertEqual(error.localizedDescription, fileFailure.localizedDescription)
        }
    }

    func testBothFailedThrowsTheAppFailure() {
        XCTAssertThrowsError(
            try DualTrackTranscription.resolve(
                app: .failure(ASRError.processingFailed("app")),
                mic: .failure(ASRError.processingFailed("mic")),
                viability: .both,
            ),
        ) { error in
            XCTAssertEqual(error.localizedDescription, ASRError.processingFailed("app").localizedDescription)
        }
    }
}
