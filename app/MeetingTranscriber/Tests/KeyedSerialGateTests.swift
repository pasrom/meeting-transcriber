@testable import MeetingTranscriber
import XCTest

@MainActor
final class KeyedSerialGateTests: XCTestCase {
    private struct Failure: Error {}

    func testASecondBodyUnderTheSameKeyRunsOnlyAfterTheFirstReturned() async {
        let gate = KeyedSerialGate()
        let held = MainActorGate()
        var events: [String] = []
        let first = Task { await gate.run("a") { events.append("first started"); await held.wait(); events.append("first ended") } }
        await waitFor(held.hasWaiter)
        let second = Task { await gate.run("a") { events.append("second started") } }
        let other = Task { await gate.run("b") { events.append("other key") } }
        await other.value
        await waitFor(events.count == 3, timeout: .milliseconds(50))
        XCTAssertEqual(events, ["first started", "other key"], "another key does not wait, the same key does")

        held.open()
        await first.value
        await second.value
        XCTAssertEqual(events, ["first started", "other key", "first ended", "second started"])
    }

    func testABodyThatThrowsFreesItsKey() async {
        let gate = KeyedSerialGate()
        do {
            try await gate.run("a") { throw Failure() }
            XCTFail("the error must reach the caller")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        var ran = false
        await gate.run("a") { ran = true }
        XCTAssertTrue(ran)
    }

    func testEveryWaiterRunsInTurn() async {
        let gate = KeyedSerialGate()
        let held = MainActorGate()
        var running = 0
        var mostAtOnce = 0
        var finished = 0
        let first = Task { await gate.run("a") { await held.wait() } }
        await waitFor(held.hasWaiter)
        let waiters = (0 ..< 3).map { _ in
            Task {
                await gate.run("a") {
                    running += 1
                    mostAtOnce = max(mostAtOnce, running)
                    await Task.yield()
                    running -= 1
                    finished += 1
                }
            }
        }
        held.open()
        await first.value
        for waiter in waiters {
            await waiter.value
        }
        XCTAssertEqual(finished, 3)
        XCTAssertEqual(mostAtOnce, 1)
    }
}
