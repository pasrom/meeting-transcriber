@testable import MeetingTranscriber
import XCTest

#if !APPSTORE
    /// The orphan reaper's `ps` snapshot has to end however `ps` misbehaves,
    /// and must hand back no table at all rather than a wrong one. Fake `ps`
    /// scripts and their children stop by themselves after three seconds,
    /// past `bound`, so a broken bound fails these tests instead of hanging
    /// them.
    final class PersistentDiagnosticLogSnapshotTests: XCTestCase {
        private typealias Row = (pid: Int32, ppid: Int32, command: String)

        private static let shortTimeout: TimeInterval = 0.3
        private static let longTimeout: TimeInterval = 2
        private static let drainGrace: TimeInterval = 0.2
        private static let bound: TimeInterval = 2.5

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
        /// printed before is not used.
        func testSnapshotGivesUpOnAPSThatDoesNotExit() async throws {
            let start = Date()

            let rows = try await snapshot("""
            echo '  900     1 /usr/bin/log stream'
            sleep 3
            """, timeout: Self.shortTimeout)

            XCTAssertTrue(rows.isEmpty)
            XCTAssertLessThan(Date().timeIntervalSince(start), Self.bound)
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
        /// drain grace, and the possibly cut table is not used.
        func testSnapshotEndsAndDiscardsTheTableWhenAChildKeepsStdoutOpen() async throws {
            let pidFile = try makeTempDirectory(prefix: "ps-snapshot").appendingPathComponent("child.pid")
            addTeardownBlock {
                if let pid = readPID(pidFile) { kill(pid, SIGKILL) }
            }
            let start = Date()

            let rows = try await snapshot("""
            echo '  900     1 /usr/bin/log stream'
            sleep 3 &
            echo $! > '\(pidFile.path)'
            """)

            XCTAssertTrue(rows.isEmpty)
            XCTAssertLessThan(Date().timeIntervalSince(start), Self.bound)
        }

        /// A `ps` that cannot be started yields no table.
        func testSnapshotReturnsNothingWhenPSCannotStart() async throws {
            let folder = try makeTempDirectory(prefix: "ps-snapshot")
            let missing = folder.appendingPathComponent("no-such-ps").path

            let rows = await PersistentDiagnosticLog.snapshotProcessTable(executable: missing)

            XCTAssertTrue(rows.isEmpty)
        }

        /// Runs a fake `ps` with `body` as its script through the snapshot.
        private func snapshot(_ body: String, timeout: TimeInterval = longTimeout) async throws -> [Row] {
            let folder = try makeTempDirectory(prefix: "ps-snapshot")
            let script = try makeExecutableScript(in: folder, name: "ps", body: body)
            return await PersistentDiagnosticLog.snapshotProcessTable(
                executable: script, timeout: timeout, drainGrace: Self.drainGrace,
            )
        }
    }
#endif
