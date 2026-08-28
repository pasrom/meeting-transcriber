@testable import MeetingTranscriber
import XCTest

final class ParakeetVocabularyConfigurationTests: XCTestCase {
    func testConfigurationKeyChangesWhenVocabularyContentsChange() {
        let first = ParakeetVocabularyConfiguration(
            path: "/tmp/terms.txt",
            bookmark: nil,
            revision: .init(fileID: 42, modificationTime: .distantPast, fileSize: 12),
        )
        let edited = ParakeetVocabularyConfiguration(
            path: "/tmp/terms.txt",
            bookmark: nil,
            revision: .init(fileID: 42, modificationTime: .distantFuture, fileSize: 16),
        )

        XCTAssertNotEqual(first, edited)
    }

    func testRefreshGenerationRejectsAnOlderConfigurationAttempt() {
        var gate = ParakeetVocabularyRefreshGate()
        let firstAttempt = gate.invalidate()
        let currentAttempt = gate.invalidate()

        XCTAssertFalse(gate.isCurrent(firstAttempt))
        XCTAssertTrue(gate.isCurrent(currentAttempt))
    }
}
