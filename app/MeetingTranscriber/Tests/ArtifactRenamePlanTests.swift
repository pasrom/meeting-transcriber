@testable import MeetingTranscriber
import XCTest

final class ArtifactRenamePlanTests: XCTestCase {
    private let dirs = ArtifactRenamePlan.Directories(
        protocols: URL(fileURLWithPath: "/out/protocols"),
        recordings: URL(fileURLWithPath: "/out/recordings"),
    )
    private let shortID = "ab12cd34"

    /// A fake filesystem: the plan only ever asks "does this URL exist?".
    private func exists(_ names: Set<String>) -> (URL) -> Bool {
        { names.contains($0.path) }
    }

    private func stem(
        _ slug: String, current: String = "20261014_1800_google_chrome_ab12cd34", existing: Set<String> = [],
    ) -> String? {
        ArtifactRenamePlan.availableStem(
            titleSlug: slug, shortID: shortID, currentStem: current,
            in: dirs, exists: exists(existing),
        )
    }

    // MARK: - availableStem

    func testFreeTitleSlugIsUsedAsIs() {
        XCTAssertEqual(stem("weekly_sync"), "weekly_sync")
    }

    func testTakenProtocolAddsShortID() {
        XCTAssertEqual(stem("weekly_sync", existing: ["/out/protocols/weekly_sync.md"]), "weekly_sync_ab12cd34")
        XCTAssertEqual(stem("weekly_sync", existing: ["/out/protocols/weekly_sync.txt"]), "weekly_sync_ab12cd34")
    }

    /// The protocol of an earlier meeting may be gone (moved or deleted by the
    /// user) while its audio is still here. That audio must still count as taken.
    func testLeftoverRecordingCountsAsTaken() {
        for suffix in [
            "_mix.wav",
            "_app.wav",
            "_mic.wav",
            "_16k.wav",
            "_app_16k.wav",
            "_mic_16k.wav",
            "_segments.json",
            "_naming.json",
            "_recording.json",
        ] {
            XCTAssertEqual(
                stem("weekly_sync", existing: ["/out/recordings/weekly_sync\(suffix)"]),
                "weekly_sync_ab12cd34",
                "a leftover weekly_sync\(suffix) must make the plain title slug unavailable",
            )
        }
    }

    func testGivesUpWhenPlainAndSuffixedStemAreBothTaken() {
        XCTAssertNil(stem("weekly_sync", existing: [
            "/out/protocols/weekly_sync.md",
            "/out/recordings/weekly_sync_ab12cd34_mix.wav",
        ]))
    }

    /// A regenerated protocol that yields the same title must not move the
    /// job's own files onto themselves or onto a second suffix.
    func testCurrentStemIsKeptWhenTitleSlugMatchesIt() {
        XCTAssertEqual(
            stem("weekly_sync", current: "weekly_sync", existing: ["/out/protocols/weekly_sync.txt"]),
            "weekly_sync",
        )
        XCTAssertEqual(
            stem("weekly_sync", current: "weekly_sync_ab12cd34", existing: ["/out/protocols/weekly_sync_ab12cd34.txt"]),
            "weekly_sync_ab12cd34",
        )
    }

    // MARK: - moves

    func testMovesCoverEveryArtifactThatExists() {
        let old = "20261014_1800_google_chrome_ab12cd34"
        let names: Set = [
            "/out/protocols/\(old).md", "/out/protocols/\(old).txt",
            "/out/recordings/\(old)_mix.wav", "/out/recordings/\(old)_app.wav", "/out/recordings/\(old)_mic.wav",
            "/out/recordings/\(old)_16k.wav", "/out/recordings/\(old)_app_16k.wav",
            "/out/recordings/\(old)_mic_16k.wav", "/out/recordings/\(old)_segments.json",
            "/out/recordings/\(old)_naming.json", "/out/recordings/\(old)_recording.json",
        ]
        let moves = ArtifactRenamePlan.moves(
            from: old, to: "weekly_sync", in: dirs,
            exists: exists(names),
        )
        XCTAssertEqual(Set(moves.map(\.from.path)), names)
        for move in moves {
            XCTAssertEqual(
                move.to.path,
                move.from.path.replacingOccurrences(of: old, with: "weekly_sync"),
                "each artifact keeps its directory and suffix, only the stem changes",
            )
        }
    }

    func testMovesSkipArtifactsThatDoNotExist() {
        let old = "weekly_sync"
        let moves = ArtifactRenamePlan.moves(
            from: old, to: "standup", in: dirs,
            exists: exists(["/out/protocols/weekly_sync.txt"]),
        )
        XCTAssertEqual(moves.map(\.from.path), ["/out/protocols/weekly_sync.txt"])
    }

    /// After a first rename the stem has no short id. Another job whose stem
    /// merely starts with it must stay untouched, which a prefix scan got wrong.
    func testMovesNeverTouchAnotherJobsFilesThatShareThePrefix() {
        let mine: Set = ["/out/recordings/weekly_sync_mix.wav", "/out/protocols/weekly_sync.txt"]
        let others: Set = [
            "/out/recordings/weekly_sync_ab12cd34_mix.wav",
            "/out/recordings/weekly_sync_retro_mix.wav",
            "/out/recordings/weekly_sync_retro_16k.wav",
            "/out/protocols/weekly_sync_retro.md",
        ]
        let moves = ArtifactRenamePlan.moves(
            from: "weekly_sync", to: "standup", in: dirs,
            exists: exists(mine.union(others)),
        )
        XCTAssertEqual(Set(moves.map(\.from.path)), mine)
    }
}
