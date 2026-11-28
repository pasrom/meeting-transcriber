@testable import MeetingTranscriber
import XCTest

/// What waits for the compactor's next pass: the user's run and the kinds
/// automatic requests owe are kept apart, so neither swallows the other.
/// Pure: the context is a plain value here.
final class RecordingCompactionBacklogTests: XCTestCase {
    private typealias Backlog = RecordingCompactionPlan.Backlog<String>

    private func drain(_ backlog: inout Backlog?) -> [RecordingCompactionPlan.Request] {
        var passes: [RecordingCompactionPlan.Request] = []
        while let next = Backlog.takeNext(from: &backlog) {
            passes.append(next.request)
        }
        return passes
    }

    func testTheUserRunGoesFirstAndTheOwedKindsFollowIt() {
        var backlog: Backlog? = Backlog(context: "a", request: .awaiting(.flac))
        backlog?.add(context: "b", request: .everyEntry)

        XCTAssertEqual(drain(&backlog), [.everyEntry, .awaiting(.flac)])
        XCTAssertNil(backlog)
    }

    /// A kind other than FLAC (dropping a mix the tracks rebuild) is owed
    /// on its own, is never merged into the user's run, and keeps its place
    /// ahead of every encode; each request runs once.
    func testEveryOwedKindKeepsItsOwnPassAndItsPlace() {
        var backlog: Backlog? = Backlog(context: "a", request: .everyEntry)
        backlog?.add(context: "a", request: .awaiting(.flac))
        backlog?.add(context: "a", request: .awaiting(.mixDrop))
        backlog?.add(context: "a", request: .awaiting(.flac))

        XCTAssertEqual(drain(&backlog), [.awaiting(.mixDrop), .everyEntry, .awaiting(.flac)])
    }

    /// The newest context wins, as for the single pending request before.
    func testTheNewestContextIsTheOneThatRuns() {
        var backlog: Backlog? = Backlog(context: "old", request: .awaiting(.flac))
        backlog?.add(context: "new", request: .awaiting(.flac))

        XCTAssertEqual(Backlog.takeNext(from: &backlog)?.context, "new")
    }

    /// Cancelling the user's run while it waits takes it out and leaves
    /// what automatic requests owe.
    func testDroppingTheUserRunKeepsTheOwedKinds() {
        var backlog: Backlog? = Backlog(context: "a", request: .everyEntry)
        backlog?.add(context: "a", request: .awaiting(.flac))

        XCTAssertTrue(Backlog.dropExplicit(from: &backlog))
        XCTAssertEqual(drain(&backlog), [.awaiting(.flac)])

        var onlyTheUsers: Backlog? = Backlog(context: "a", request: .everyEntry)
        XCTAssertTrue(Backlog.dropExplicit(from: &onlyTheUsers))
        XCTAssertNil(onlyTheUsers, "an empty backlog is no backlog")
        XCTAssertFalse(Backlog.dropExplicit(from: &onlyTheUsers), "nothing to drop")
    }

    func testTheBacklogSaysWhetherTheUserRunWaits() {
        var backlog: Backlog? = Backlog(context: "a", request: .awaiting(.flac))
        XCTAssertFalse(backlog?.explicit ?? true)
        backlog?.add(context: "a", request: .everyEntry)
        XCTAssertTrue(backlog?.explicit ?? false)
    }
}
