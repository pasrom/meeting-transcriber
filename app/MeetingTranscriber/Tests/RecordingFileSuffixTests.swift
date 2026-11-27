@testable import MeetingTranscriber
import XCTest

/// Track names in the two containers a kept recording can be in. The staging
/// parser stays WAV-only, the output-folder parser takes both.
final class RecordingFileSuffixTests: XCTestCase {
    func testKeptTrackReturnsTheTrackForEveryKeptContainer() throws {
        for suffix in RecordingFileSuffix.all {
            for fileExtension in RecordingFileSuffix.keptExtensions {
                let name = "20270115_1200_weekly_sync_ab12cd34" + RecordingFileSuffix.kept(suffix, extension: fileExtension)
                let track = try XCTUnwrap(RecordingFileSuffix.keptTrack(of: name), name)
                XCTAssertEqual(track.stem, "20270115_1200_weekly_sync_ab12cd34")
                XCTAssertEqual(track.suffix, suffix, "the track comes back as its WAV suffix")
                XCTAssertEqual(track.fileExtension, fileExtension)
            }
        }
    }

    func testAPartialCopyIsNoTrack() {
        XCTAssertNil(RecordingFileSuffix.keptTrack(of: ".meeting_mix.partial.flac"))
        XCTAssertNil(RecordingFileSuffix.keptTrack(of: "meeting" + RecordingFileSuffix.mixStaging))
        XCTAssertNil(RecordingFileSuffix.keptTrack(of: "meeting_mix.m4a"))
    }

    func testKeptTrackHonoursTheExtensionsAsked() {
        XCTAssertNil(RecordingFileSuffix.keptTrack(of: "meeting_app.flac", extensions: [RecordingFileSuffix.wavExtension]))
        XCTAssertNotNil(RecordingFileSuffix.keptTrack(of: "meeting_app.wav", extensions: [RecordingFileSuffix.wavExtension]))
    }

    /// The staging scans (orphan recovery, record-only) parse with
    /// `stripSuffix`, and a compressed file must never read as a track there.
    func testStripSuffixStillRefusesACompressedTrack() {
        for suffix in RecordingFileSuffix.compressed {
            XCTAssertNil(RecordingFileSuffix.stripSuffix(from: "meeting" + suffix), suffix)
        }
        XCTAssertEqual(RecordingFileSuffix.stripSuffix(from: "meeting_mic.wav")?.suffix, RecordingFileSuffix.mic)
    }

    func testTheCompressedSuffixesAreTheTracksAsFLAC() {
        XCTAssertEqual(RecordingFileSuffix.compressed, ["_mix.flac", "_app.flac", "_mic.flac"])
    }
}
