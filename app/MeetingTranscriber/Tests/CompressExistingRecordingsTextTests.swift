@testable import MeetingTranscriber
import XCTest

/// The wording of the confirmation and the summary.
final class CompressExistingRecordingsTextTests: XCTestCase {
    /// The confirmation says what is converted and, by name, what is not.
    func testTheConfirmationNamesTheCountAndWhatIsLeftAlone() {
        let message = CompressExistingRecordingsText.confirmationMessage(count: 4)

        XCTAssertTrue(message.hasPrefix("4 recordings in the output folder still have WAV tracks."), message)
        for phrase in [
            "imported files", "record-only recordings", "recordings processed by earlier versions",
            "recordings of meetings cancelled before their audio reached the output folder", "files renamed by hand", "Recordings in another output folder",
            "files not downloaded from iCloud", "checked against its WAV before the WAV is removed",
        ] {
            XCTAssertTrue(message.contains(phrase), phrase)
        }
        XCTAssertTrue(CompressExistingRecordingsText.confirmationMessage(count: 1).hasPrefix("1 recording in the output folder still has"))
    }

    func testTheSummaryCountsWhatWasDoneAndWhatWasLeft() {
        var summary = RecordingCompactionSummary(explicit: true)
        summary.compressed = 5
        summary.resumed = 1
        summary.bytesSaved = 2_000_000
        summary.skippedTracks = [.evicted: 2, .lowSpace: 1, .cancelled: 1]
        summary.skippedEntries = [.inUse: 1, .otherRoot: 2, .noWAVTrack: 3]
        summary.cancelled = true

        XCTAssertEqual(
            CompressExistingRecordingsText.summary(summary),
            "Compressed 6 files, saving 2 MB. 3 files kept as WAV (2 not downloaded from iCloud, 1 not enough free space). "
                + "3 recordings skipped (1 in use by a meeting being processed, 2 in another output folder). "
                + "Cancelled: the rest stays WAV and can be compressed later.",
        )
    }

    func testARunThatCouldNotStartSaysWhy() {
        var summary = RecordingCompactionSummary(explicit: true)
        summary.notRun = .outputFolderNotOpened

        XCTAssertEqual(CompressExistingRecordingsText.summary(summary), "Nothing was compressed: the output folder could not be opened.")
        summary.notRun = .flacNotConfirmed
        XCTAssertEqual(
            CompressExistingRecordingsText.summary(summary),
            "Nothing was compressed: it is not yet confirmed that this Mac can write FLAC.",
        )
        XCTAssertEqual(CompressExistingRecordingsText.summary(RecordingCompactionSummary(explicit: true)), "No file was compressed.")
    }

    func testProgressCountsFiles() {
        var progress = RecordingCompactionProgress(total: 3)
        progress.advance()
        XCTAssertEqual(CompressExistingRecordingsText.progress(progress), "Compressing recordings: 1 of 3 files done.")
        XCTAssertEqual(CompressExistingRecordingsText.progress(nil), "Compressing recordings\u{2026}")
        XCTAssertEqual(
            CompressExistingRecordingsText.progress(progress, waiting: true),
            "Waiting for another conversion to finish\u{2026}",
        )
    }
}
