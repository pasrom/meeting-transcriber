@testable import MeetingTranscriber
import XCTest

/// The pure decision behind the recording retention setting. Every fact the
/// decision needs is passed in, so each rule is pinned here without a queue, a
/// clock or a disk.
final class RecordingRetentionPolicyTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Volumes/Archive/Protocols")
    private let recordedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86400

    private var mix: URL {
        root.appendingPathComponent("recordings/20270115_1200_sync_ab12cd34_mix.wav")
    }

    private var app: URL {
        root.appendingPathComponent("recordings/20270115_1200_sync_ab12cd34_app.wav")
    }

    private var mic: URL {
        root.appendingPathComponent("recordings/20270115_1200_sync_ab12cd34_mic.wav")
    }

    private var protocolFile: URL {
        root.appendingPathComponent("protocols/20270115_1200_sync_ab12cd34.md")
    }

    private func entry(eligible: Bool = true) -> RetainedRecording {
        RetainedRecording(
            jobID: UUID(), paths: [mix, app, mic], root: root,
            recordedAt: recordedAt,
            eligibleAt: eligible ? recordedAt.addingTimeInterval(3700) : nil,
            outputPath: eligible ? protocolFile : nil,
        )
    }

    private func decide(
        _ entry: RetainedRecording,
        now: Date? = nil,
        enabled: Bool = true,
        days: Int = 0,
        excluded: Set<String> = [],
        missing: Set<URL> = [],
        rootExists: Bool = true,
        scopedRoot: URL? = nil,
        empty: Set<URL> = [],
        resolved: [String: String] = [:],
        recordingsListable: Bool = true,
    ) -> RecordingRetentionDecision {
        RecordingRetentionPolicy.decide(
            entry,
            now: now ?? recordedAt.addingTimeInterval(day),
            settings: RecordingRetentionSettings(enabled: enabled, days: days),
            environment: .init(
                excludedPaths: excluded, scopedRoot: scopedRoot,
                fileExists: { url in url == self.root ? rootExists : !missing.contains(url) },
                hasContent: { url in !missing.contains(url) && !empty.contains(url) },
                resolve: { url in resolved[url.standardizedFileURL.path].map(URL.init(fileURLWithPath:)) ?? url },
                canList: { _ in recordingsListable },
            ),
        )
    }

    func testDeletesEveryPathOfAnEligibleEntryPastTheThreshold() {
        XCTAssertEqual(decide(entry()), .delete([mix, app, mic]))
    }

    func testSwitchedOffKeepsEverything() {
        XCTAssertEqual(decide(entry(), enabled: false), .keep(.disabled))
    }

    /// Nothing is deleted before the job's outputs were written, however old.
    func testAnEntryWithoutWrittenOutputsIsKept() {
        XCTAssertEqual(
            decide(entry(eligible: false), now: recordedAt.addingTimeInterval(400 * day)),
            .keep(.awaitingOutputs),
        )
    }

    /// Days count from the recording date, not from when the outputs were
    /// written: one second short of the threshold keeps, the threshold deletes.
    func testThresholdCountsFromTheRecordingDate() {
        let target = entry()
        XCTAssertEqual(
            decide(target, now: recordedAt.addingTimeInterval(30 * day - 1), days: 30),
            .keep(.withinRetention),
        )
        XCTAssertEqual(
            decide(target, now: recordedAt.addingTimeInterval(30 * day), days: 30),
            .delete([mix, app, mic]),
        )
    }

    /// Zero days means as soon as the outputs exist; there is no separate mode.
    func testZeroDaysDeletesAsSoonAsEligible() {
        let target = entry()
        XCTAssertEqual(
            decide(target, now: target.eligibleAt ?? .distantPast, days: 0),
            .delete([mix, app, mic]),
        )
    }

    /// A running job reads `_app.wav` and `_mic.wav` too, so one claimed track
    /// protects the whole entry, the mix included.
    func testAnyPathInUseKeepsTheWholeEntry() {
        for inUse in [mix, app, mic] {
            XCTAssertEqual(
                decide(entry(), excluded: [RecordingRetentionPolicy.pathKey(inUse)]),
                .keep(.inUse),
                "\(inUse.lastPathComponent) in use must keep all three tracks",
            )
        }
    }

    /// Exclusion compares standardized paths, so a different spelling of the
    /// same file still protects it.
    func testInUseMatchesANonStandardSpellingOfThePath() {
        let spelled = root.appendingPathComponent("recordings/./20270115_1200_sync_ab12cd34_app.wav")
        XCTAssertEqual(
            decide(entry(), excluded: [RecordingRetentionPolicy.pathKey(spelled)]),
            .keep(.inUse),
        )
    }

    /// An unplugged drive must not read as "the files are gone": dropping the
    /// entry would leave the files on the drive for good once it is back.
    func testUnreachableRootKeepsTheEntry() {
        XCTAssertEqual(
            decide(entry(), missing: [mix, app, mic], rootExists: false),
            .keep(.rootUnreachable),
        )
    }

    /// With the root reachable and every file gone (the user deleted them), the
    /// entry has nothing left to protect or delete.
    func testAllFilesGoneUnderAReachableRootDropsTheEntry() {
        XCTAssertEqual(decide(entry(), missing: [mix, app, mic]), .drop(.filesGone))
    }

    /// Files the user already removed are skipped; the rest is still deleted.
    func testDeletesOnlyThePathsThatStillExist() {
        XCTAssertEqual(decide(entry(), missing: [app, mic]), .delete([mix]))
    }

    // MARK: - Review findings

    /// The output that made the entry eligible has to exist when the audio is
    /// deleted, not only when the job finished: a protocol or transcript the
    /// user deleted since leaves the audio as the only copy.
    func testAMissingOutputKeepsTheAudio() {
        XCTAssertEqual(decide(entry(), missing: [protocolFile]), .keep(.outputMissing))
    }

    /// A protocol exported to Notion in place of the local Markdown left no
    /// local file by design; the page is the output, so the audio may go.
    func testAnOutputExportedToNotionNeedsNoLocalFile() {
        var exported = entry()
        exported.outputExported = true
        XCTAssertEqual(decide(exported, missing: [protocolFile]), .delete([mix, app, mic]))
    }

    /// A path outside the root's `recordings` folder is never deleted, however
    /// it got into the registry; the rest of the entry still is.
    func testAPathOutsideTheRecordingsFolderIsSkipped() {
        let outside = URL(fileURLWithPath: "/Users/someone/Documents/keep_mix.wav")
        let escaping = root.appendingPathComponent("recordings/../protocols/notes_mix.wav")
        var target = entry()
        target.paths = [mix, outside, escaping]
        XCTAssertEqual(decide(target), .delete([mix]))

        target.paths = [outside, escaping]
        XCTAssertEqual(decide(target), .keep(.outsideRoot), "only outside paths: kept, never dropped")
    }

    /// A file inside `recordings` that is a symlink to somewhere else is
    /// judged by where it resolves to.
    func testAPathThatResolvesOutsideTheRecordingsFolderIsSkipped() {
        let target = entry()
        let elsewhere = URL(fileURLWithPath: "/Users/someone/Music/take_mix.wav")
        XCTAssertEqual(decide(target, resolved: [mix.path: elsewhere.path]), .delete([app, mic]))
    }

    /// The other direction: a link written outside the folder that points into
    /// it is still outside. Deleting it would remove a file the user keeps
    /// elsewhere, so the path as written has to pass too.
    func testALinkOutsideTheFolderThatPointsIntoItIsSkipped() {
        let link = URL(fileURLWithPath: "/Users/someone/Desktop/sync_mix.wav")
        var target = entry()
        target.paths = [link, app]
        XCTAssertEqual(decide(target, resolved: [link.path: mix.path]), .delete([app]))
    }

    /// A folder outside that is itself a link to `recordings`: as resolved the
    /// files look inside, as written they are not, and only that keeps them.
    func testAFolderLinkOutsideThatPointsIntoRecordingsIsSkipped() {
        let linkedFolder = URL(fileURLWithPath: "/Users/someone/Shortcut")
        let viaLink = linkedFolder.appendingPathComponent(mix.lastPathComponent)
        var target = entry()
        target.paths = [viaLink, app]
        let resolved = [linkedFolder.path: root.appendingPathComponent("recordings").path, viaLink.path: mix.path]
        XCTAssertEqual(decide(target, resolved: resolved), .delete([app]))
    }

    /// An entry that never became eligible (a failed protocol, a cancelled
    /// job) whose audio the user has since deleted has nothing left to keep.
    func testAnEntryNeverEligibleWhoseFilesAreGoneIsDropped() {
        XCTAssertEqual(decide(entry(eligible: false), missing: [mix, app, mic]), .drop(.filesGone))
    }

    /// The same for an entry not due yet.
    func testAnEntryNotDueYetWhoseFilesAreGoneIsDropped() {
        XCTAssertEqual(decide(entry(), days: 36500, missing: [mix, app, mic]), .drop(.filesGone))
    }

    /// A job that is still running holds its paths: if its files are briefly
    /// not visible, its entry is kept rather than dropped, since nothing would
    /// register it again.
    func testAnEntryWhosePathsAreInUseIsKeptEvenIfItsFilesAreNotVisible() {
        XCTAssertEqual(
            decide(entry(eligible: false), excluded: [RecordingRetentionPolicy.pathKey(app)], missing: [mix, app, mic]),
            .keep(.inUse),
        )
    }

    /// Dropping for missing files still never reads an unreachable root as
    /// "files gone", eligible or not.
    func testAnEntryNeverEligibleUnderAnUnreachableRootIsKept() {
        XCTAssertNotEqual(decide(entry(eligible: false), missing: [mix, app, mic], rootExists: false), .drop(.filesGone))
    }

    /// A root that is there but whose recordings folder cannot be listed (the
    /// sandbox without that folder's grant) makes every file look missing.
    /// That is not "the files are gone": dropping the entry would leave them
    /// on disk for good once access is back.
    func testFilesThatCannotBeSeenAreNotTakenForGone() {
        XCTAssertEqual(
            decide(entry(), missing: [mix, app, mic], recordingsListable: false),
            .keep(.rootUnreachable),
        )
    }

    /// An empty output file is not a written output.
    func testAnEmptyOutputKeepsTheAudio() {
        XCTAssertEqual(decide(entry(), empty: [protocolFile]), .keep(.outputMissing))
    }

    /// An output folder reached through a symlink: files that are gone cannot
    /// be resolved themselves, but their folder can, so they still count as
    /// inside and the entry is dropped rather than kept as "outside".
    func testFilesGoneUnderASymlinkedRootStillDropTheEntry() {
        let real = "/Volumes/Disk/Archive/Protocols/recordings"
        let resolved = [
            root.appendingPathComponent("recordings").path: real,
        ]
        XCTAssertEqual(decide(entry(), missing: [mix, app, mic], resolved: resolved), .drop(.filesGone))
    }

    /// Output and audio both deleted by hand: nothing is left to protect, so
    /// the entry goes instead of lingering as "output missing" for good.
    func testOutputAndAudioBothGoneDropTheEntry() {
        XCTAssertEqual(decide(entry(), missing: [mix, app, mic, protocolFile]), .drop(.filesGone))
    }

    /// Under a live scope on one output folder, an entry recorded under a
    /// different one cannot be reached and is kept as such.
    func testAnEntryUnderAnotherRootThanTheScopedOneIsUnreachable() {
        let other = URL(fileURLWithPath: "/Users/someone/NewProtocols")
        XCTAssertEqual(decide(entry(), scopedRoot: other), .keep(.rootUnreachable))
        XCTAssertEqual(decide(entry(), scopedRoot: root), .delete([mix, app, mic]))
    }

    /// A negative count cannot come from the Settings stepper, but a hand-edited
    /// default could hold one; it reads as zero rather than as "never".
    func testNegativeThresholdReadsAsZero() {
        XCTAssertEqual(decide(entry(), days: -5), .delete([mix, app, mic]))
    }

    // MARK: - Pass summary

    /// The pass's log line carries counts and reason names in a fixed order,
    /// so two passes with the same outcome read the same.
    func testThePassSummaryCountsEachOutcomeInAFixedOrder() {
        var summary = RecordingRetentionPassSummary()
        let decisions: [RecordingRetentionDecision] = [
            .keep(.inUse), .delete([mix, app]), .keep(.awaitingOutputs), .drop(.filesGone), .keep(.inUse),
        ]
        decisions.forEach { summary.count($0) }
        summary.deletedFiles = 2

        XCTAssertEqual(
            summary.logLine,
            "Retention pass: entries 5, due 1 (files 2), deleted files 2, dropped 1, kept 3 (awaitingOutputs 1, inUse 2)",
        )
    }

    /// A pass that keeps everything still says why, which is what tells a pass
    /// that ran from one that never started.
    func testAPassThatKeepsEverythingStillReportsWhy() {
        var summary = RecordingRetentionPassSummary()
        summary.count(.keep(.withinRetention))

        XCTAssertEqual(
            summary.logLine,
            "Retention pass: entries 1, due 0 (files 0), deleted files 0, dropped 0, kept 1 (withinRetention 1)",
        )
    }
}
