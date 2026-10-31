@testable import MeetingTranscriber
import XCTest

#if !APPSTORE
    /// The orphan reaper's `ps` snapshot has to end however `ps` misbehaves,
    /// and must hand back no table at all rather than a wrong one. A `ps`
    /// that does not end, or a child holding its output, is a `HeldFake`.
    final class PersistentDiagnosticLogSnapshotTests: XCTestCase {
        private typealias Row = (pid: Int32, ppid: Int32, command: String)

        /// The rows the fake prints come back parsed.
        func testSnapshotParsesWhatPSPrints() async throws {
            let rows = try await snapshot("""
            echo '  900     1 /usr/bin/log stream --predicate x'
            echo '  901   900 /bin/sleep 5'
            """)

            XCTAssertEqual(rows.map(\.pid), [900, 901])
            XCTAssertEqual(rows.map(\.ppid), [1, 900])
            XCTAssertEqual(try XCTUnwrap(rows.first).command, "/usr/bin/log stream --predicate x")
        }

        /// A `ps` that never exits is stopped at the limit, and what it
        /// printed before is not used. The limit must pass after the row has
        /// been read (`Self.printRead`), or the discard would not be tested.
        func testSnapshotGivesUpOnAPSThatDoesNotExit() async throws {
            let held = try makeHeldFake(in: makeTempDirectory(prefix: "ps-snapshot"), name: "held-ps")
            let script = try makeFakePS("""
            \(Self.printRead("  900     1 /usr/bin/log stream"))
            exec '\(held.path)'
            """)

            let rows = try await passLimit(of: held, "ps was not stopped at the limit") { clock, timeout in
                await Self.snapshot(script: script, timeout: timeout, clock: clock)
            }.get()

            XCTAssertTrue(rows.isEmpty, "the rows of a ps stopped at the limit were used: \(rows)")
        }

        /// A `ps` that exits non-zero still printed whole rows, and they are
        /// used.
        func testSnapshotKeepsTheRowsOfAPSThatExitsNonZero() async throws {
            let rows = try await snapshot("""
            echo '  900     1 /usr/bin/log stream'
            exit 1
            """)

            XCTAssertEqual(rows.map(\.pid), [900])
        }

        /// A row that is not valid UTF-8 is dropped without costing the
        /// others.
        func testSnapshotKeepsTheOtherRowsWhenOneIsNotUTF8() async throws {
            let rows = try await snapshot("""
            printf '  900     1 /bin/cat \\377\\n  901     1 /usr/bin/log stream\\n'
            """)

            XCTAssertEqual(rows.map(\.pid), [901])
        }

        /// A process `ps` left behind holding stdout ends the read after the
        /// drain grace, and the possibly cut table is not used. The child
        /// holds stdout until the test ends, so only the drain grace can end
        /// the read. A short one is safe: the row has been read before `ps`
        /// exits (`Self.printRead`), so the grace cannot end the read before
        /// the table that must be discarded has arrived.
        func testSnapshotEndsAndDiscardsTheTableWhenAChildKeepsStdoutOpen() async throws {
            let child = try makeHeldFake(in: makeTempDirectory(prefix: "ps-snapshot"), name: "child")

            let rows = try await snapshot("""
            \(Self.printRead("  900     1 /usr/bin/log stream"))
            \(child.inBackground)
            """, drainGrace: 0.2)

            XCTAssertTrue(rows.isEmpty, "the rows of a cut table were used: \(rows)")
            child.assertNotRunOut("the read waited for the child holding stdout")
        }

        /// A `ps` that cannot be started yields no table.
        func testSnapshotReturnsNothingWhenPSCannotStart() async throws {
            let folder = try makeTempDirectory(prefix: "ps-snapshot")
            let missing = folder.appendingPathComponent("no-such-ps").path

            let rows = await PersistentDiagnosticLog.snapshotProcessTable(executable: missing)

            XCTAssertTrue(rows.isEmpty)
        }

        /// Runs a fake `ps` with `body` as its script through the snapshot.
        private func snapshot(_ body: String, drainGrace: TimeInterval = HeldFake.noLimit) async throws -> [Row] {
            try await Self.snapshot(script: makeFakePS(body), drainGrace: drainGrace)
        }

        /// The snapshot of the fake `ps` at `script`. Limits not under test
        /// are `HeldFake.noLimit`.
        private static func snapshot(
            script: String, timeout: TimeInterval = HeldFake.noLimit, drainGrace: TimeInterval = HeldFake.noLimit,
            clock: any Clock<Duration> = SuspendingClock(),
        ) async -> [Row] {
            await PersistentDiagnosticLog.snapshotProcessTable(
                executable: script, timeout: timeout, drainGrace: drainGrace, clock: clock,
            )
        }

        /// The most a pipe holds on macOS, which grows a pipe's buffer to at
        /// most 64 KiB.
        private static let pipeCapacity = 64 * 1024

        /// Shell lines that print `row` and return only once the snapshot has
        /// read it. They follow it with blank lines, which the parser skips,
        /// four times `pipeCapacity`: the write can finish only once the
        /// reader has drained all but one buffer, and it hands each chunk on
        /// before reading the next, so the row is in the snapshot's stream by
        /// then. A stream ended or cut after that keeps it, so a test that
        /// the table is discarded cannot pass on a row that never arrived.
        private static func printRead(_ row: String) -> String {
            "echo '\(row)'\nyes '' | head -n \(4 * pipeCapacity)"
        }

        /// A fake `ps` with `body` as its script, in a folder of its own.
        private func makeFakePS(_ body: String) throws -> String {
            try makeExecutableScript(in: makeTempDirectory(prefix: "ps-snapshot"), name: "ps", body: body)
        }
    }
#endif
