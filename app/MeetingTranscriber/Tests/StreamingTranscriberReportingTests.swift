@testable import MeetingTranscriber
import XCTest

/// A live re-transcription that throws `CancellationError` was stopped, for
/// instance while the engine still loads its model, and must not be logged as
/// a transcribe error; a real failure still is.
final class StreamingTranscriberReportingTests: XCTestCase {
    func testACancelledTranscriptionIsNotReportedAsAFailure() {
        XCTAssertFalse(StreamingTranscriber.isReportable(CancellationError()), "a stop was reported as a failure")
        XCTAssertTrue(StreamingTranscriber.isReportable(TranscriptionError.modelNotLoaded()))
    }
}
