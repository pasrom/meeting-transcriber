@testable import MeetingTranscriber
import XCTest

/// `speakers.json` is the one persisted store whose loss cannot be recovered
/// by re-running a job, so these pin that no write path can silently drop it.
final class SpeakerMatcherPersistenceTests: XCTestCase { // swiftlint:disable:this balanced_xctest_lifecycle
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var dbPath: URL!
    private var db: SpeakerDBFixture!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUpWithError() throws {
        tmpDir = try makeTempDirectory(prefix: "SpeakerMatcherPersistenceTests")
        db = SpeakerDBFixture(dir: tmpDir)
        dbPath = db.dbPath
    }

    @discardableResult
    private func confirm(
        _ matcher: SpeakerMatcher, name: String, embedding: [Float] = [1, 0, 0],
    ) -> SpeakerMatcher.ConfirmationOutcome {
        matcher.updateDB(mapping: ["SPEAKER_0": name], embeddings: ["SPEAKER_0": embedding])
    }

    private func makeDBUnreadable() throws {
        try makeUnreadable(dbPath)
    }

    // MARK: - Undecodable file

    func testMutateOnUndecodableDBPreservesOriginalBytes() throws {
        let original = Data("[{\"name\":\"Alice\",\"embeddings\":[[1,0,0]] TRUNCATED".utf8)
        try original.write(to: dbPath)
        let (matcher, log) = db.makeMatcher()

        let outcome = confirm(matcher, name: "Bob")

        let quarantined = try db.quarantinedFiles()
        XCTAssertEqual(quarantined.count, 1, "undecodable DB must be copied aside, not overwritten")
        let copiedTo = try XCTUnwrap(quarantined.first)
        XCTAssertEqual(try Data(contentsOf: copiedTo), original)
        XCTAssertEqual(log.problems, [.copiedAside(dbPath.deletingLastPathComponent().appendingPathComponent(copiedTo.lastPathComponent))])
        // The confirmation itself still lands in a fresh DB.
        XCTAssertEqual(matcher.loadDB().map(\.name), ["Bob"])
        XCTAssertEqual(outcome.stored, ["Bob"])
    }

    func testQuarantinedFileIsOwnerOnly() throws {
        try Data("not json".utf8).write(to: dbPath)
        let (matcher, _) = db.makeMatcher()

        confirm(matcher, name: "Bob")

        let quarantined = try XCTUnwrap(db.quarantinedFiles().first)
        let attrs = try FileManager.default.attributesOfItem(atPath: quarantined.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    func testSecondQuarantineDoesNotReplaceTheFirst() throws {
        let first = Data("first broken".utf8)
        let second = Data("second broken".utf8)
        let (matcher, log) = db.makeMatcher()

        try first.write(to: dbPath)
        confirm(matcher, name: "Bob")
        try second.write(to: dbPath)
        confirm(matcher, name: "Carol")

        let contents = try Set(db.quarantinedFiles().map { try Data(contentsOf: $0) })
        XCTAssertEqual(contents, [first, second])
        XCTAssertEqual(log.problems.count, 2, "each quarantine copied a different file, so each is reported")
    }

    /// A sync tool caught mid-write leaves a file that decodes a moment later.
    /// Quarantining it would replace every voice with a near-empty DB, which
    /// the same sync tool then spreads to every other machine.
    func testFileThatBecomesValidOnRereadIsNotQuarantined() throws {
        try Data("[{\"name\":\"Ali".utf8).write(to: dbPath)
        let complete = StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]])
        let completeData = try JSONEncoder().encode([complete])
        var settles = 0
        let path: URL = dbPath
        let (matcher, log) = db.makeMatcher {
            settles += 1
            try? completeData.write(to: path)
        }

        confirm(matcher, name: "Bob")

        XCTAssertEqual(settles, 1)
        XCTAssertTrue(try db.quarantinedFiles().isEmpty)
        XCTAssertEqual(Set(matcher.loadDB().map(\.name)), ["Alice", "Bob"])
        XCTAssertTrue(log.problems.isEmpty)
    }

    func testFileStillUndecodableAfterRereadIsQuarantined() throws {
        try Data("not json".utf8).write(to: dbPath)
        var settles = 0
        let (matcher, _) = db.makeMatcher { settles += 1 }

        confirm(matcher, name: "Bob")

        XCTAssertEqual(settles, 1)
        XCTAssertEqual(try db.quarantinedFiles().count, 1)
    }

    /// A file that stayed undecodable and could not be copied is not going to
    /// settle; waiting again would stall every (mostly main-actor) caller.
    func testUnmovableUndecodableDBIsNotWaitedOnTwice() throws {
        try XCTSkipIf(geteuid() == 0, "root writes into a mode-0555 directory, so the move would succeed")
        try Data("not json".utf8).write(to: dbPath)
        try db.setPermissions(0o555, of: tmpDir)
        let dirPath: String = tmpDir.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dirPath)
        }
        var settles = 0
        let (matcher, _) = db.makeMatcher { settles += 1 }

        confirm(matcher, name: "Bob")
        confirm(matcher, name: "Carol")

        XCTAssertEqual(settles, 1)
    }

    func testDecodableDBIsNotReread() {
        var settles = 0
        let (matcher, _) = db.makeMatcher { settles += 1 }

        confirm(matcher, name: "Bob")
        confirm(matcher, name: "Carol")

        XCTAssertEqual(settles, 0, "only an undecodable read is worth a second look")
    }

    // MARK: - Missing or blank file

    func testMissingDBStartsEmptyWithoutQuarantine() throws {
        let (matcher, log) = db.makeMatcher()

        confirm(matcher, name: "Bob")

        XCTAssertEqual(matcher.loadDB().map(\.name), ["Bob"])
        XCTAssertTrue(try db.quarantinedFiles().isEmpty)
        XCTAssertTrue(log.problems.isEmpty)
    }

    func testEmptyDBCountsAsMissing() throws {
        try Data().write(to: dbPath)
        let (matcher, log) = db.makeMatcher()

        confirm(matcher, name: "Bob")

        XCTAssertEqual(matcher.loadDB().map(\.name), ["Bob"])
        XCTAssertTrue(try db.quarantinedFiles().isEmpty)
        XCTAssertTrue(log.problems.isEmpty, "an empty file holds no voices, so there is nothing to warn about")
    }

    func testWhitespaceOnlyDBCountsAsMissing() throws {
        try Data(" \n\t\r\n".utf8).write(to: dbPath)
        let (matcher, log) = db.makeMatcher()

        confirm(matcher, name: "Bob")

        XCTAssertEqual(matcher.loadDB().map(\.name), ["Bob"])
        XCTAssertTrue(try db.quarantinedFiles().isEmpty)
        XCTAssertTrue(log.problems.isEmpty)
    }

    // MARK: - Unreadable file

    func testDBThatFailsToReadIsLeftInPlaceAndNotWritten() throws {
        // A read error (here: no permission) says nothing about the contents,
        // so the file may be intact and must be neither copied nor replaced.
        let (matcher, log) = db.makeMatcher()
        matcher.saveDB([StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]])])
        let original = try Data(contentsOf: dbPath)
        try makeDBUnreadable()

        let outcome = confirm(matcher, name: "Bob")

        try db.setPermissions(0o600, of: dbPath)
        XCTAssertEqual(try Data(contentsOf: dbPath), original)
        XCTAssertTrue(try db.quarantinedFiles().isEmpty)
        XCTAssertEqual(log.problems, [.leftInPlace])
        XCTAssertEqual(outcome.persistence, .dbUnavailable)
        XCTAssertTrue(outcome.stored.isEmpty, "nothing reached the disk, so nothing counts as stored")
    }

    func testUndecodableDBThatCannotBeMovedIsLeftInPlaceAndNotWritten() throws {
        try XCTSkipIf(geteuid() == 0, "root writes into a mode-0555 directory, so the move would succeed")
        // Readable file, read-only directory: the decode fails but the move
        // aside does too, so the file must stay and nothing may replace it.
        let original = Data("not json".utf8)
        try original.write(to: dbPath)
        try db.setPermissions(0o555, of: tmpDir)
        // Restore so the temp-dir teardown can delete it, even if an assertion throws.
        let dirPath: String = tmpDir.path
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dirPath)
        }
        let (matcher, log) = db.makeMatcher()

        let mutation = matcher.mutateDB { stored -> Int in
            stored.append(StoredSpeaker(name: "Bob", embeddings: [[1, 0, 0]]))
            return 42
        }

        XCTAssertEqual(mutation.value, 42, "callers still get the block's result")
        XCTAssertEqual(mutation.persistence, .dbUnavailable)
        XCTAssertEqual(try Data(contentsOf: dbPath), original)
        XCTAssertTrue(try db.quarantinedFiles().isEmpty)
        XCTAssertEqual(log.problems, [.leftInPlace])
    }

    // MARK: - Write failure

    func testSaveFailureIsReportedAndLeavesTheDBAsItWas() throws {
        let (matcher, log) = db.makeMatcher()
        matcher.saveDB([StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]])])
        let original = try Data(contentsOf: dbPath)
        try db.blockDBWrites()

        let outcome = confirm(matcher, name: "Bob")

        XCTAssertEqual(outcome.persistence, .writeFailed)
        XCTAssertTrue(outcome.stored.isEmpty)
        XCTAssertEqual(log.problems, [.saveFailed(copiedTo: nil)])
        XCTAssertEqual(try Data(contentsOf: dbPath), original)
    }

    /// The quarantine has already copied the original aside when the fresh
    /// write fails. The original stays in place (the atomic replace never ran),
    /// the copy survives, and the user is told where it is.
    func testSaveFailureAfterQuarantineKeepsTheCorruptCopyAndNamesIt() throws {
        let original = Data("not json".utf8)
        try original.write(to: dbPath)
        try db.blockDBWrites()
        let (matcher, log) = db.makeMatcher()

        let outcome = confirm(matcher, name: "Bob")

        let quarantined = try XCTUnwrap(db.quarantinedFiles().first)
        XCTAssertEqual(try Data(contentsOf: quarantined), original)
        XCTAssertEqual(try Data(contentsOf: dbPath), original, "the original stays in place")
        let expected = dbPath.deletingLastPathComponent().appendingPathComponent(quarantined.lastPathComponent)
        XCTAssertEqual(log.problems, [.saveFailed(copiedTo: expected)])
        XCTAssertEqual(outcome.persistence, .writeFailed)
        XCTAssertTrue(outcome.stored.isEmpty)
    }

    /// The original stays in place after a failed write, so every later write
    /// finds the same undecodable file. While it is unchanged, that must not
    /// stall the caller for the re-read, copy it again, or notify again.
    func testWriteThatKeepsFailingOnAnUndecodableDBDoesNotRepeatItself() throws {
        try Data("not json".utf8).write(to: dbPath)
        try db.blockDBWrites()
        var settles = 0
        let (matcher, log) = db.makeMatcher { settles += 1 }

        confirm(matcher, name: "Bob")
        confirm(matcher, name: "Carol")
        confirm(matcher, name: "Dave")

        XCTAssertEqual(settles, 1)
        XCTAssertEqual(try db.quarantinedFiles().count, 1)
        XCTAssertEqual(log.problems.count, 1)
    }

    // MARK: - Reporting

    func testUnreadableDBIsReportedOnceUntilTheFileChanges() throws {
        let (matcher, log) = db.makeMatcher()
        matcher.saveDB([StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]])])
        try makeDBUnreadable()

        confirm(matcher, name: "Bob")
        confirm(matcher, name: "Carol")
        // A new matcher, as each pipeline job and RPC call creates one.
        let (other, otherLog) = db.makeMatcher()
        confirm(other, name: "Dave")

        XCTAssertEqual(log.problems, [.leftInPlace], "the same unreadable file is reported once")
        XCTAssertTrue(otherLog.problems.isEmpty, "dedup is per file, not per matcher")

        // The file is replaced (here by a different, still unreadable one):
        // a new state is worth a new report.
        try db.setPermissions(0o600, of: dbPath)
        try Data("[\n]".utf8).write(to: dbPath)
        try db.setPermissions(0o000, of: dbPath)
        confirm(matcher, name: "Erin")

        XCTAssertEqual(log.problems, [.leftInPlace, .leftInPlace])
    }

    func testSuccessfulSaveRearmsTheReport() throws {
        let (matcher, log) = db.makeMatcher()
        matcher.saveDB([StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]])])
        let blocker = tmpDir.appendingPathComponent("speakers.json.tmp")
        try db.blockDBWrites()
        confirm(matcher, name: "Bob")
        confirm(matcher, name: "Bob")
        XCTAssertEqual(log.problems, [.saveFailed(copiedTo: nil)])

        try FileManager.default.removeItem(at: blocker)
        confirm(matcher, name: "Bob")
        try db.blockDBWrites()
        confirm(matcher, name: "Bob")

        XCTAssertEqual(log.problems, [.saveFailed(copiedTo: nil), .saveFailed(copiedTo: nil)])
    }

    /// `dbLock` is not recursive. A callback that runs under it and reaches a
    /// matcher (directly, or through whatever the notification triggers)
    /// would deadlock the process.
    func testProblemIsReportedAfterTheLockIsReleased() throws {
        try Data("not json".utf8).write(to: dbPath)
        let path: URL = dbPath
        var nestedFinished = false
        let matcher = SpeakerMatcher(
            dbPath: dbPath,
            onDBProblem: { _ in
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    SpeakerMatcher(dbPath: path) { _ in }.mutateDB { _ in }
                    done.signal()
                }
                // Bounded, so a regression fails here instead of hanging.
                nestedFinished = done.wait(timeout: .now() + 2) == .success
            },
            settleBeforeReread: {},
        )

        confirm(matcher, name: "Bob")

        XCTAssertTrue(nestedFinished, "the callback ran while dbLock was still held")
    }

    // MARK: - User notification

    func testMovedAsideNotificationNamesTheQuarantineFile() throws {
        let notifier = RecordingNotifier()
        let copy = tmpDir.appendingPathComponent("speakers.json.corrupt-20260101-120000")

        SpeakerMatcher.notifyDBProblem(.copiedAside(copy), via: notifier)

        let call = try XCTUnwrap(notifier.calls.first)
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(call.title, "Voice profiles could not be read")
        XCTAssertTrue(call.body.contains("speakers.json.corrupt-20260101-120000"), call.body)
    }

    func testLeftInPlaceNotificationSaysNothingIsSaved() throws {
        let notifier = RecordingNotifier()

        SpeakerMatcher.notifyDBProblem(.leftInPlace, via: notifier)

        let call = try XCTUnwrap(notifier.calls.first)
        XCTAssertEqual(notifier.calls.count, 1)
        XCTAssertEqual(call.title, "Voice profiles could not be read")
        XCTAssertTrue(call.body.contains("not being saved"), call.body)
    }

    func testSaveFailedNotificationNamesTheQuarantineFileWhenThereIsOne() {
        let notifier = RecordingNotifier()
        let copy = tmpDir.appendingPathComponent("speakers.json.corrupt-20260101-120000")

        SpeakerMatcher.notifyDBProblem(.saveFailed(copiedTo: copy), via: notifier)
        SpeakerMatcher.notifyDBProblem(.saveFailed(copiedTo: nil), via: notifier)

        XCTAssertEqual(notifier.calls.map(\.title), Array(repeating: "Voice profiles could not be saved", count: 2))
        XCTAssertTrue(notifier.calls[0].body.contains("speakers.json.corrupt-20260101-120000"))
        XCTAssertTrue(notifier.calls[1].body.contains("not being saved"))
    }

    func testReadsDoNotMoveUndecodableDB() throws {
        let original = Data("not json".utf8)
        try original.write(to: dbPath)
        let (matcher, log) = db.makeMatcher()

        XCTAssertTrue(matcher.loadDB().isEmpty)
        XCTAssertTrue(matcher.allSpeakerNames().isEmpty)
        XCTAssertTrue(matcher.match(embeddings: ["SPEAKER_0": [1, 0, 0]]).values.allSatisfy { $0 == "SPEAKER_0" })

        XCTAssertEqual(try Data(contentsOf: dbPath), original)
        XCTAssertTrue(try db.quarantinedFiles().isEmpty)
        XCTAssertTrue(log.problems.isEmpty)
    }

    // MARK: - Edits on a DB that was not read

    func testEditsOnUnreadableDBReportNotSavedRatherThanNotFound() throws {
        let (matcher, _) = db.makeMatcher()
        matcher.saveDB([
            StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Bob", embeddings: [[0, 1, 0]]),
        ])
        try makeDBUnreadable()

        XCTAssertEqual(matcher.renameSpeaker(from: "Alice", to: "Alicia"), .notSaved)
        XCTAssertEqual(matcher.deleteSpeaker(name: "Alice"), .notSaved)
        XCTAssertEqual(matcher.mergeSpeakers(from: "Alice", into: "Bob"), .notSaved)
    }

    /// An edit on an undecodable DB quarantines it and saves an empty one.
    /// "Not found" would read as "no such speaker" and hide that the file
    /// changed, so callers would skip their refresh.
    func testEditsOnUndecodableDBReportTheReset() throws {
        func quarantine() throws -> String {
            try Data("not json".utf8).write(to: dbPath)
            return "speakers.json.corrupt-"
        }
        let (matcher, _) = db.makeMatcher()

        let prefix = try quarantine()
        guard case let .replacedCorruptDB(renamedTo) = matcher.renameSpeaker(from: "Alice", to: "Alicia") else {
            XCTFail("rename must report the reset")
            return
        }
        XCTAssertTrue(renamedTo.lastPathComponent.hasPrefix(prefix))
        _ = try quarantine()
        guard case .replacedCorruptDB = matcher.deleteSpeaker(name: "Alice") else {
            XCTFail("delete must report the reset")
            return
        }
        _ = try quarantine()
        guard case .replacedCorruptDB = matcher.mergeSpeakers(from: "Alice", into: "Bob") else {
            XCTFail("merge must report the reset")
            return
        }
        XCTAssertEqual(matcher.deleteSpeaker(name: "Alice"), .notFound, "a decodable empty DB is plain not-found")
    }

    // MARK: - Production wiring

    func testFactoryReportsThroughTheInjectedNotifier() throws {
        try Data("not json".utf8).write(to: dbPath)
        let notifier = RecordingNotifier()

        SpeakerMatcher.factory(dbPath: dbPath, notifier: notifier)().deleteSpeaker(name: "Alice")

        XCTAssertEqual(notifier.calls.map(\.title), ["Voice profiles could not be read"])
    }

    // MARK: - Non-finite embeddings

    func testNonFiniteEmbeddingIsSkippedWithoutLosingTheMutation() throws {
        let (matcher, _) = db.makeMatcher()
        matcher.saveDB([StoredSpeaker(name: "Alice", embeddings: [[1, 0, 0]], centroid: [1, 0, 0])])

        let outcome = matcher.updateDB(
            mapping: ["SPEAKER_0": "Alice", "SPEAKER_1": "Bob"],
            embeddings: [
                "SPEAKER_0": [0.9, 0.1, 0],
                "SPEAKER_1": [.nan, .infinity, -.infinity],
            ],
            speakingTimes: ["SPEAKER_0": 10],
        )
        // A NaN for an existing speaker must not reach its running-mean centroid.
        let nanForAlice = matcher.updateDB(
            mapping: ["SPEAKER_0": "Alice"],
            embeddings: ["SPEAKER_0": [.nan, 0, 0]],
            speakingTimes: ["SPEAKER_0": 10],
        )

        XCTAssertEqual(outcome.stored, ["Alice"])
        XCTAssertEqual(outcome.unusableVoice, ["Bob"])
        XCTAssertEqual(nanForAlice.stored, [])
        XCTAssertEqual(nanForAlice.unusableVoice, ["Alice"])
        let loaded = matcher.loadDB()
        XCTAssertEqual(loaded.map(\.name), ["Alice"], "the non-finite label is skipped")
        let alice = try XCTUnwrap(loaded.first)
        XCTAssertEqual(alice.useCount, 1, "only the finite confirmation counts, and it must persist")
        XCTAssertTrue(try XCTUnwrap(alice.centroid).allSatisfy(\.isFinite))
        XCTAssertTrue(alice.embeddings.joined().allSatisfy(\.isFinite))
    }

    func testNameTaughtByAnotherLabelIsNotReportedUnusable() {
        let (matcher, _) = db.makeMatcher()

        let outcome = matcher.updateDB(
            mapping: ["SPEAKER_0": "Alice", "SPEAKER_1": "Alice"],
            embeddings: ["SPEAKER_0": [1, 0, 0], "SPEAKER_1": [.nan, 0, 0]],
        )

        XCTAssertEqual(outcome.stored, ["Alice"])
        XCTAssertTrue(outcome.unusableVoice.isEmpty)
    }
}
