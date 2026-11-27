@testable import MeetingTranscriber
import XCTest

/// Which entries a compaction run takes and what it does with each track.
/// Pure: the file system is a set of paths.
final class RecordingCompactionPlanTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/compaction-plan/Output")
    private var recordings: URL {
        root.appendingPathComponent("recordings")
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let off = RecordingRetentionSettings(enabled: false, days: 0)

    private func entry(
        _ names: [String], under root: URL? = nil, awaiting: Set<CompactionKind> = [.flac], eligible: Bool = true,
    ) -> RetainedRecording {
        let root = root ?? self.root
        var entry = RetainedRecording(
            jobID: UUID(), paths: names.map { root.appendingPathComponent("recordings").appendingPathComponent($0) },
            root: root, recordedAt: now.addingTimeInterval(-86400), eligibleAt: eligible ? now : nil,
        )
        entry.awaiting = awaiting
        return entry
    }

    private func environment(excluded: Set<String> = []) -> RecordingRetentionPolicy.Environment {
        RecordingRetentionPolicy.Environment(
            excludedPaths: excluded, scopedRoot: nil,
            fileExists: { [root] url in url.path == root.path },
            hasContent: { _ in true }, resolve: { $0 }, canList: { _ in true },
        )
    }

    private func select(
        _ entries: [RetainedRecording],
        excluded: Set<String> = [],
        retention: RecordingRetentionSettings? = nil,
        environment: RecordingRetentionPolicy.Environment? = nil,
    ) -> RecordingCompactionPlan.Selection {
        RecordingCompactionPlan.select(entries, request: .awaiting(.flac), in: .init(
            outputRoot: root, now: now,
            retention: retention ?? off, environment: environment ?? self.environment(excluded: excluded),
        ))
    }

    // MARK: - Entries

    func testOnlyListedWAVTracksAreCandidates() {
        let selection = select([entry(["m_mix.wav", "m_app.flac", "m_mic.wav", "m_recording.json", "m_16k.wav"])])

        XCTAssertEqual(selection.candidates.first?.tracks.map(\.lastPathComponent), ["m_mix.wav", "m_mic.wav"])
    }

    func testTheSidecarIsNeverACandidate() {
        XCTAssertFalse(RecordingCompactionPlan.isWAVTrack(recordings.appendingPathComponent("m_recording.json")))
        XCTAssertEqual(select([entry(["m_recording.json"])]).candidates.first?.tracks, [])
    }

    func testAHeldEntryIsSkippedWhole() {
        let held = entry(["m_mix.wav", "m_app.wav"])
        let selection = select([held], excluded: [RecordingRetentionPolicy.pathKey(held.paths[1])])

        XCTAssertEqual(selection.candidates, [])
        XCTAssertEqual(selection.skipped, [.inUse: 1])
    }

    func testAnEntryUnderAnotherRootIsSkippedAndCounted() {
        let selection = select([entry(["m_mix.wav"], under: URL(fileURLWithPath: "/elsewhere"))])

        XCTAssertEqual(selection.candidates, [])
        XCTAssertEqual(selection.skipped, [.otherRoot: 1])
    }

    func testAMissingRootIsSkipped() {
        let env = RecordingRetentionPolicy.Environment(
            excludedPaths: [], scopedRoot: nil, fileExists: { _ in false }, hasContent: { _ in true },
            resolve: { $0 }, canList: { _ in true },
        )
        XCTAssertEqual(select([entry(["m_mix.wav"])], environment: env).skipped, [.rootMissing: 1])
    }

    func testAPathOutsideTheRecordingsFolderIsSkipped() {
        var outside = entry(["m_mix.wav"])
        outside.paths.append(root.appendingPathComponent("elsewhere/m_app.wav"))
        let selection = select([outside])

        XCTAssertEqual(selection.candidates.first?.tracks.map(\.lastPathComponent), ["m_mix.wav"])
        XCTAssertEqual(selection.outsideFolder, 1)
    }

    func testAnEntryDueForDeletionIsSkipped() {
        let selection = select([entry(["m_mix.wav"])], retention: RecordingRetentionSettings(enabled: true, days: 0))

        XCTAssertEqual(selection.skipped, [.due: 1])
    }

    func testAnEntryNotAwaitingIsNoCandidateForTheAutomaticRun() {
        let selection = select([entry(["m_mix.wav"], awaiting: []), entry(["n_mix.wav"], awaiting: [.mixDrop])])

        XCTAssertEqual(selection.candidates, [])
        XCTAssertEqual(selection.skipped, [.notAwaiting: 2])
    }

    // MARK: - Tracks

    private let stamp = RecordingCompactionPlan.TrackFacts.Stamp(size: 1_000_000, modified: Date(timeIntervalSince1970: 1))

    private func action(
        _ source: RecordingCompactionPlan.TrackFacts.Source? = nil,
        evicted: Bool = false, free: Int64? = 1 << 40, destination: Bool = false, listed: Bool = false,
    ) -> RecordingCompactionPlan.TrackAction {
        RecordingCompactionPlan.action(
            for: .init(source: source ?? .regular(stamp), evicted: evicted, freeBytes: free, destinationExists: destination),
            destinationListed: listed,
        )
    }

    func testARegularWAVWithRoomIsEncoded() {
        XCTAssertEqual(action(), .encode)
        XCTAssertEqual(action(free: nil), .encode, "an unreadable free-space figure does not block")
    }

    func testALinkOrFolderIsSkipped() {
        XCTAssertEqual(action(.notRegular), .skip(.notRegularFile))
    }

    /// A stat error other than "no such file" is no evidence the WAV is
    /// gone, and may pass.
    func testAnUnreadableSourceIsSkippedForLater() {
        XCTAssertEqual(action(.unreadable, destination: true, listed: true), .skip(.unreadable))
        XCTAssertFalse(RecordingCompactionPlan.TrackSkip.unreadable.isPermanent)
    }

    func testLiveFactsTellAMissingFileFromOneThatCannotBeRead() throws {
        let dir = try makeTempDirectory(prefix: "compaction-facts")
        let missing = dir.appendingPathComponent("gone_mix.wav")
        XCTAssertEqual(RecordingCompaction.liveFacts(source: missing, destination: dir.appendingPathComponent("gone_mix.flac")).source, .missing)

        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let behind = locked.appendingPathComponent("m_mix.wav")
        XCTAssertEqual(
            RecordingCompaction.liveFacts(source: behind, destination: locked.appendingPathComponent("m_mix.flac")).source,
            .unreadable, "a folder that cannot be searched is no proof the file is gone",
        )
    }

    func testAnEvictedFileIsSkippedAndCounted() {
        XCTAssertEqual(action(evicted: true), .skip(.evicted))
        XCTAssertEqual(action(evicted: true, destination: true, listed: true), .skip(.evicted))
        XCTAssertFalse(RecordingCompactionPlan.TrackSkip.evicted.isPermanent, "a download can bring it back")
    }

    func testTooLittleFreeSpaceSkipsTheTrack() {
        XCTAssertEqual(action(free: stamp.size + RecordingCompactionPlan.spaceMargin - 1), .skip(.lowSpace))
        XCTAssertEqual(action(free: stamp.size + RecordingCompactionPlan.spaceMargin), .encode)
    }

    func testAnUnlistedDestinationIsTakenAndAListedOneResumes() {
        XCTAssertEqual(action(destination: true), .skip(.destinationTaken))
        XCTAssertEqual(action(destination: true, listed: true), .resume)
    }

    func testAGoneSourceIsForgottenOnlyWhenItsCopyIsListedAndThere() {
        XCTAssertEqual(action(.missing, destination: true, listed: true), .forgetSource)
        XCTAssertEqual(action(.missing, destination: false, listed: true), .nothingToDo)
        XCTAssertEqual(action(.missing, destination: true, listed: false), .nothingToDo)
    }

    func testOnlyFailuresThatRepeatClearTheMark() {
        let permanent = RecordingCompactionPlan.TrackSkip.allCases.filter(\.isPermanent)
        XCTAssertEqual(
            Set(permanent),
            [.notRegularFile, .destinationTaken, .notIntegerPCM, .lengthMismatch, .mismatch, .notNativeFLAC],
        )
    }

    // MARK: - The sweep's pattern

    func testThePartialPatternIsExactlyTheCompressorsPartials() {
        let partial = KeptRecordingCompressor.partialURL(for: recordings.appendingPathComponent("m_app.flac"))
        XCTAssertTrue(RecordingCompaction.isPartialCopy(partial.lastPathComponent))
        for name in [".DS_Store", ".m_app.partial.wav", "m_app.partial.flac", ".notes.partial.flac", ".m_mix.wav.partial", "m_app.flac"] {
            XCTAssertFalse(RecordingCompaction.isPartialCopy(name), name)
        }
    }
}
