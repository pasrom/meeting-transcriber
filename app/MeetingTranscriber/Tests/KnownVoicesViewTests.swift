@testable import MeetingTranscriber
import ViewInspector
import XCTest

@MainActor
final class KnownVoicesViewTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var tmpDir: URL!
    private var dbPath: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownVoicesViewTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        dbPath = tmpDir.appendingPathComponent("speakers.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testViewRendersWithEmptyDB() throws {
        let view = KnownVoicesView(matcher: SpeakerMatcher(dbPath: dbPath))
        XCTAssertNoThrow(try view.inspect())
    }

    func testViewRendersWithSpeakers() throws {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([
            StoredSpeaker(name: "Speaker A", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Speaker B", embeddings: [[0, 1, 0]]),
            StoredSpeaker(name: "Speaker C", embeddings: [[0, 0, 1]]),
        ])
        let view = KnownVoicesView(matcher: matcher)
        XCTAssertNoThrow(try view.inspect())
    }

    // MARK: - onMutate callback (cache invalidation gap, follow-up to #155)

    //
    // KnownVoicesView mutates the SpeakerMatcher's on-disk DB directly via
    // rename / delete / merge. Without notifying anyone, the PipelineQueue's
    // cached `knownSpeakerNames` (#155) goes stale — the next naming dialog
    // shows obsolete chips. The view now fires `onMutate` after every
    // successful mutation so the caller (SpeakersSettingsView wires it to
    // `pipelineQueue.refreshKnownSpeakerNames()`) can keep the cache fresh.

    func testRenameInvokesOnMutate() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "Old", embeddings: [[1, 0, 0]])])

        var calls = 0
        // Swift's trailing-closure disambiguation forces an explicit `onMutate:`
        // label here (KnownVoicesView has multiple closure params); SwiftLint's
        // trailing_closure rule disagrees but the compiler wins.
        // swiftlint:disable:next trailing_closure
        let view = KnownVoicesView(matcher: matcher, onMutate: { calls += 1 })

        view.performRename(from: "Old", to: "New")

        XCTAssertEqual(calls, 1)
    }

    func testDeleteInvokesOnMutate() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "Doomed", embeddings: [[1, 0, 0]])])

        var calls = 0
        // Swift's trailing-closure disambiguation forces an explicit `onMutate:`
        // label here (KnownVoicesView has multiple closure params); SwiftLint's
        // trailing_closure rule disagrees but the compiler wins.
        // swiftlint:disable:next trailing_closure
        let view = KnownVoicesView(matcher: matcher, onMutate: { calls += 1 })

        view.performDelete(name: "Doomed")

        XCTAssertEqual(calls, 1)
    }

    func testMergeInvokesOnMutate() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([
            StoredSpeaker(name: "From", embeddings: [[1, 0, 0]]),
            StoredSpeaker(name: "Into", embeddings: [[0, 1, 0]]),
        ])

        var calls = 0
        // Swift's trailing-closure disambiguation forces an explicit `onMutate:`
        // label here (KnownVoicesView has multiple closure params); SwiftLint's
        // trailing_closure rule disagrees but the compiler wins.
        // swiftlint:disable:next trailing_closure
        let view = KnownVoicesView(matcher: matcher, onMutate: { calls += 1 })

        view.performMerge(from: "From", into: "Into")

        XCTAssertEqual(calls, 1)
    }

    func testMissingOnMutateIsHandledGracefully() {
        let matcher = SpeakerMatcher(dbPath: dbPath)
        matcher.saveDB([StoredSpeaker(name: "X", embeddings: [[1, 0, 0]])])
        let view = KnownVoicesView(matcher: matcher) // onMutate omitted
        // Mutations without a callback must not crash.
        view.performRename(from: "X", to: "Y")
    }
}
