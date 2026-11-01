@testable import MeetingTranscriber
import XCTest

/// A `speakers.json` that is still a JSON array but holds some entries that
/// cannot be used keeps every entry that can, instead of sending all of them
/// into quarantine for one bad one. The original file is still copied aside
/// unchanged before anything is written, so the dropped entries survive.
final class SpeakerDBSalvageTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var dbPath: URL!
    private var db: SpeakerDBFixture!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUpWithError() throws {
        tmpDir = try makeTempDirectory(prefix: "SpeakerDBSalvageTests")
        db = SpeakerDBFixture(dir: tmpDir)
        dbPath = db.dbPath
    }

    private func decode(_ json: String) throws -> (names: [String], dropped: Int) {
        let result = try SpeakerMatcher.decodeSalvaging(Data(json.utf8))
        return (result.kept.map(\.name), result.dropped)
    }

    /// Two usable entries (one current, one legacy without a centroid that
    /// still uses the single `embedding` key) around one whose `useCount` has
    /// the wrong type.
    private let mixedDB = """
    [
      {"name":"Alice","embeddings":[[1,0,0]],"centroid":[1,0,0],"centroidSampleCount":1,"useCount":4},
      {"name":"Broken","embeddings":[[0,1,0]],"useCount":"many"},
      {"name":"Legacy","embedding":[0,0,1]}
    ]
    """

    @discardableResult
    private func writeMixedDB() throws -> Data {
        let data = Data(mixedDB.utf8)
        try data.write(to: dbPath)
        return data
    }

    // MARK: - Decoding entry by entry

    func testMixedEntriesKeepTheUsableOnes() throws {
        let result = try decode(mixedDB)

        XCTAssertEqual(result.names, ["Alice", "Legacy"])
        XCTAssertEqual(result.dropped, 1)
    }

    func testEntryWithAWrongTypeIsDropped() throws {
        let result = try decode("""
        [{"name":"A","embeddings":[[1]],"centroid":"oops"},{"name":7,"embeddings":[[1]]},{"name":"B","embeddings":[[1]]}]
        """)

        XCTAssertEqual(result.names, ["B"])
        XCTAssertEqual(result.dropped, 2)
    }

    func testEntryWithoutANameIsDropped() throws {
        let result = try decode(#"[{"embeddings":[[1]]},{"name":"B","embeddings":[[1]]}]"#)

        XCTAssertEqual(result.names, ["B"])
        XCTAssertEqual(result.dropped, 1)
    }

    func testNonObjectElementsAreDropped() throws {
        let result = try decode(#"[null,3,"x",[],{"name":"B","embeddings":[[1]]}]"#)

        XCTAssertEqual(result.names, ["B"])
        XCTAssertEqual(result.dropped, 4)
    }

    /// Plain JSON has no NaN token; a value too large for `Float` is the
    /// nearest a file gets, and it must not come back as infinity.
    func testCentroidOverflowingFloatIsDropped() throws {
        let result = try decode(#"[{"name":"A","embeddings":[[1]],"centroid":[1e39]},{"name":"B","embeddings":[[1]]}]"#)

        XCTAssertEqual(result.names, ["B"])
        XCTAssertEqual(result.dropped, 1)
    }

    func testEmbeddingOverflowingFloatIsDropped() throws {
        let result = try decode(#"[{"name":"A","embeddings":[[1,1e39]]},{"name":"B","embeddings":[[1]]}]"#)

        XCTAssertEqual(result.names, ["B"])
        XCTAssertEqual(result.dropped, 1)
    }

    /// A damaged voice field used to load as no voice at all, so the entry
    /// counted as intact and the next write saved it empty, unreported.
    func testEntryWithADamagedEmbeddingsFieldIsDropped() throws {
        let result = try decode("""
        [{"name":"A","embeddings":"x"},{"name":"L","embedding":[[1]]},{"name":"B","embeddings":[[1]]}]
        """)

        XCTAssertEqual(result.names, ["B"])
        XCTAssertEqual(result.dropped, 2)
    }

    /// Before the entry-by-entry decode such an entry loaded with its legacy
    /// voice; it must not be dropped now.
    func testDamagedEmbeddingsFieldBesideAValidLegacyOneKeepsTheLegacyVoice() throws {
        let result = try SpeakerMatcher.decodeSalvaging(Data(#"[{"name":"M","embeddings":"x","embedding":[2]}]"#.utf8))

        XCTAssertEqual(result.kept.map(\.embeddings), [[[2]]])
        XCTAssertEqual(result.dropped, 0)
    }

    /// Absent or null still falls back to the legacy single `embedding`.
    func testEmbeddingsAbsentOrNullStillFallsBackToTheLegacyKey() throws {
        let result = try SpeakerMatcher.decodeSalvaging(Data("""
        [{"name":"A","embedding":[1,2]},{"name":"B","embeddings":null,"embedding":[3]},{"name":"C"}]
        """.utf8))

        XCTAssertEqual(result.kept.map(\.embeddings), [[[1, 2]], [[3]], []])
        XCTAssertEqual(result.dropped, 0)
    }

    func testEmptyArrayKeepsNothingAndDropsNothing() throws {
        let result = try decode("[]")

        XCTAssertEqual(result.names, [])
        XCTAssertEqual(result.dropped, 0)
    }

    func testTopLevelThatIsNotAnArrayIsNotSalvaged() {
        XCTAssertThrowsError(try decode(#"{"name":"A","embeddings":[[1]]}"#))
        XCTAssertThrowsError(try decode(#""speakers""#))
    }

    func testDataThatIsNotJSONIsNotSalvaged() {
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode(#"[{"name":"A","embeddings":[[1]]} TRUNCATED"#))
    }

    func testReadClassifiesTheFileByWhatItHolds() throws {
        try Data(#"[{"name":"A","embeddings":[[1]]}]"#.utf8).write(to: dbPath)
        guard case .loaded = SpeakerMatcher.readDB(at: dbPath) else { XCTFail("a clean file is loaded"); return }

        try writeMixedDB()
        guard case let .salvaged(kept, dropped) = SpeakerMatcher.readDB(at: dbPath) else {
            XCTFail("a partly usable array is salvaged")
            return
        }
        XCTAssertEqual(kept.map(\.name), ["Alice", "Legacy"])
        XCTAssertEqual(dropped, 1)

        try Data(#"{"A":[[1]]}"#.utf8).write(to: dbPath)
        guard case .undecodable = SpeakerMatcher.readDB(at: dbPath) else {
            XCTFail("a file that is not an array is undecodable as before")
            return
        }
    }

    // MARK: - Writing a salvaged DB

    func testWriteKeepsUsableEntriesAndSetsTheOriginalAsideUnchanged() throws {
        let original = try writeMixedDB()
        let (matcher, log) = db.makeMatcher()

        let outcome = matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])

        XCTAssertEqual(outcome.persistence, .saved)
        XCTAssertEqual(outcome.stored, ["Bob"])
        let quarantined = try db.quarantinedFiles()
        XCTAssertEqual(quarantined.count, 1)
        let copiedTo = try XCTUnwrap(quarantined.first)
        XCTAssertEqual(try Data(contentsOf: copiedTo), original, "the dropped entry must survive in the copy")
        XCTAssertEqual(log.problems, [.salvaged(copiedTo: tmpDir.appendingPathComponent(copiedTo.lastPathComponent), kept: 2, dropped: 1)])

        // The new file is a plain array (older builds and the legacy-format
        // fast path read it) holding only usable entries.
        let written = try Data(contentsOf: dbPath)
        XCTAssertEqual(written.first, UInt8(ascii: "["))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: written) as? [[String: Any]])
        guard case let .loaded(speakers) = SpeakerMatcher.readDB(at: dbPath) else {
            XCTFail("the written DB must decode cleanly")
            return
        }
        XCTAssertEqual(speakers.map(\.name), ["Alice", "Legacy", "Bob"])
        let alice = try XCTUnwrap(speakers.first { $0.name == "Alice" })
        XCTAssertEqual(alice.useCount, 4)
        XCTAssertEqual(alice.centroid, [1, 0, 0])
        let legacy = try XCTUnwrap(speakers.first { $0.name == "Legacy" })
        XCTAssertNil(legacy.centroid, "a legacy entry stays legacy until it is confirmed")
        XCTAssertEqual(legacy.embeddings, [[0, 0, 1]])
    }

    func testReadsUseTheSalvagedEntriesAndNeverMoveTheFile() throws {
        let original = try writeMixedDB()
        let (matcher, log) = db.makeMatcher()

        for _ in 0 ..< 3 {
            XCTAssertEqual(matcher.loadDB().map(\.name), ["Alice", "Legacy"])
            XCTAssertEqual(Set(matcher.allSpeakerNames()), ["Alice", "Legacy"])
        }
        XCTAssertEqual(matcher.match(embeddings: ["SPEAKER_0": [1, 0, 0]])["SPEAKER_0"], "Alice")

        XCTAssertEqual(try Data(contentsOf: dbPath), original)
        XCTAssertTrue(try db.quarantinedFiles().isEmpty)
        XCTAssertTrue(log.problems.isEmpty)
    }

    func testRepeatedWritesSetTheFileAsideOnlyOnce() throws {
        try writeMixedDB()
        let (matcher, log) = db.makeMatcher()

        matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])
        matcher.updateDB(mapping: ["SPEAKER_0": "Carol"], embeddings: ["SPEAKER_0": [1, 1, 0]])
        // A fresh matcher, as every production call site builds one.
        db.makeMatcher().0.deleteSpeaker(name: "Carol")

        XCTAssertEqual(try db.quarantinedFiles().count, 1)
        XCTAssertEqual(log.problems.count, 1)
        XCTAssertEqual(Set(SpeakerMatcher(dbPath: dbPath).loadDB().map(\.name)), ["Alice", "Legacy", "Bob"])
    }

    /// A file caught mid-write is cut off, so it is not a JSON array. A
    /// complete array with bad entries is not going to settle, and the wait
    /// would stall the (mostly main-actor) caller for nothing.
    func testSalvageDoesNotWaitForAReread() throws {
        try writeMixedDB()
        var settles = 0
        let (matcher, _) = db.makeMatcher { settles += 1 }

        matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])

        XCTAssertEqual(settles, 0)
        XCTAssertEqual(try db.quarantinedFiles().count, 1)
    }

    /// The dropped entries exist only in the original file, so a salvage that
    /// cannot copy it aside must not write the kept ones over it.
    func testSalvageThatCannotCopyTheFileWritesNothing() throws {
        try XCTSkipIf(geteuid() == 0, "root writes into a mode-0555 directory, so the move would succeed")
        let original = try writeMixedDB()
        try db.setPermissions(0o555, of: tmpDir)
        let dirPath: String = tmpDir.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dirPath)
        }
        let (matcher, log) = db.makeMatcher()

        let outcome = matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])

        XCTAssertEqual(outcome.persistence, .dbUnavailable)
        XCTAssertEqual(try Data(contentsOf: dbPath), original)
        XCTAssertTrue(try db.quarantinedFiles().isEmpty)
        XCTAssertEqual(log.problems, [.leftInPlace])
    }

    /// The new file only takes the path through an atomic replace, so a
    /// failed write leaves the original in place, untouched, and the readable
    /// voices stay in use. The copy made before the write stays as well.
    func testSaveFailureAfterSalvageLeavesTheOriginalInPlace() throws {
        let original = try writeMixedDB()
        try db.blockDBWrites()
        let (matcher, log) = db.makeMatcher()

        let outcome = matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])

        XCTAssertEqual(outcome.persistence, .writeFailed)
        XCTAssertEqual(try Data(contentsOf: dbPath), original)
        let copy = try XCTUnwrap(db.quarantinedFiles().first)
        XCTAssertEqual(try Data(contentsOf: copy), original)
        XCTAssertEqual(log.problems, [.saveFailed(copiedTo: tmpDir.appendingPathComponent(copy.lastPathComponent))])
        XCTAssertEqual(matcher.loadDB().map(\.name), ["Alice", "Legacy"], "the readable voices stay in use")

        // A write that keeps failing on the unchanged file neither copies it
        // again nor reports it again.
        matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])
        XCTAssertEqual(try db.quarantinedFiles(), [copy])
        XCTAssertEqual(log.problems.count, 1)

        // Once writing works, the same copy stands for the quarantine.
        try FileManager.default.removeItem(at: tmpDir.appendingPathComponent("speakers.json.tmp"))
        matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])

        XCTAssertEqual(matcher.loadDB().map(\.name), ["Alice", "Legacy", "Bob"])
        XCTAssertEqual(try db.quarantinedFiles(), [copy])
        XCTAssertEqual(try Data(contentsOf: copy), original)
    }

    /// A copy from an earlier failed write is reused only while it holds the
    /// very bytes the next write would replace. One that was edited (a hand
    /// repair, a sync tool) is no copy of the original any more.
    func testChangedCopyIsNotReusedForTheNextWrite() throws {
        let original = try writeMixedDB()
        try db.blockDBWrites()
        let (matcher, _) = db.makeMatcher()
        matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])
        let first = try XCTUnwrap(db.quarantinedFiles().first)
        try Data("[]".utf8).write(to: first)

        try FileManager.default.removeItem(at: tmpDir.appendingPathComponent("speakers.json.tmp"))
        matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])

        let fresh = try db.quarantinedFiles().filter { $0.lastPathComponent != first.lastPathComponent }
        XCTAssertEqual(fresh.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fresh.first)), original)
    }

    /// Unlocked readers (the live caption matcher runs off the main actor)
    /// must never find the path empty while a write is under way: between
    /// the quarantine and the write the original is still in place.
    func testOriginalStaysInPlaceUntilTheWriteReplacesIt() throws {
        for damaged in [mixedDB, "not json"] {
            try Data(damaged.utf8).write(to: dbPath)
            var duringWrite: SpeakerMatcher.ReadOutcome?
            let path: URL = dbPath
            let (matcher, _) = db.makeMatcher()

            matcher.mutateDB { _ in duringWrite = SpeakerMatcher.readDB(at: path) }

            switch duringWrite {
            case .salvaged, .undecodable: break
            default: XCTFail("a reader during the write saw \(String(describing: duringWrite)) for \(damaged)")
            }
        }
    }

    // MARK: - Edits on a salvaged DB

    /// An edit that finds its name among the kept entries is applied as
    /// usual. One whose name was dropped answers the reset: "not found" would
    /// hide that the name may be in the set-aside copy.
    func testEditsActOnTheKeptEntriesAndReportADroppedName() throws {
        let (matcher, _) = db.makeMatcher()

        try writeMixedDB()
        XCTAssertEqual(matcher.renameSpeaker(from: "Alice", to: "Alicia"), .renamed)
        XCTAssertEqual(Set(matcher.loadDB().map(\.name)), ["Alicia", "Legacy"])

        try writeMixedDB()
        guard case let .replacedCorruptDB(copiedTo) = matcher.deleteSpeaker(name: "Broken") else {
            XCTFail("a dropped name must report the reset")
            return
        }
        XCTAssertTrue(copiedTo.lastPathComponent.hasPrefix("speakers.json.corrupt-"))

        try writeMixedDB()
        XCTAssertEqual(matcher.mergeSpeakers(from: "Legacy", into: "Alice"), .applied)
        XCTAssertEqual(matcher.loadDB().map(\.name), ["Alice"])
    }

    // MARK: - What the user is told

    func testSalvageNotificationCountsKeptAndDroppedProfiles() throws {
        let notifier = RecordingNotifier()
        let copy = tmpDir.appendingPathComponent("speakers.json.corrupt-20260101-120000")

        SpeakerMatcher.notifyDBProblem(.salvaged(copiedTo: copy, kept: 40, dropped: 1), via: notifier)

        let call = try XCTUnwrap(notifier.calls.first)
        XCTAssertEqual(call.title, "Some voice profiles could not be read")
        XCTAssertTrue(call.body.contains("40 voice profiles were kept"), call.body)
        XCTAssertTrue(call.body.contains("1 voice profile could not be read and was left out"), call.body)
        XCTAssertTrue(call.body.contains("speakers.json.corrupt-20260101-120000"), call.body)
        XCTAssertFalse(call.body.contains("Speakers need to be named again"), "kept speakers need no renaming: \(call.body)")
        XCTAssertTrue(call.body.contains("not merged"), "a left-out speaker named again is a new profile: \(call.body)")
    }

    /// Nothing kept is the same loss as a file that does not decode at all,
    /// so it is reported the same way.
    func testArrayWithNothingUsableIsReportedAsMovedAside() throws {
        try Data(#"[{"name":7},null]"#.utf8).write(to: dbPath)
        let (matcher, log) = db.makeMatcher()

        matcher.updateDB(mapping: ["SPEAKER_0": "Bob"], embeddings: ["SPEAKER_0": [0, 1, 1]])

        let copiedTo = try XCTUnwrap(db.quarantinedFiles().first)
        XCTAssertEqual(log.problems, [.copiedAside(tmpDir.appendingPathComponent(copiedTo.lastPathComponent))])
        XCTAssertEqual(matcher.loadDB().map(\.name), ["Bob"])
    }

    func testFactoryReportsTheSalvageThroughTheInjectedNotifier() throws {
        try writeMixedDB()
        let notifier = RecordingNotifier()

        SpeakerMatcher.factory(dbPath: dbPath, notifier: notifier)().renameSpeaker(from: "Alice", to: "Alicia")

        XCTAssertEqual(notifier.calls.map(\.title), ["Some voice profiles could not be read"])
        XCTAssertTrue(notifier.calls.first?.body.contains("2 voice profiles were kept") ?? false)
    }
}
