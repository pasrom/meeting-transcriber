@testable import AudioTapLib
import XCTest

/// Tests for `ProcessTreeEnumerator.pidsRooted(in:)`.
///
/// We drive the matching logic through the test seam that takes injected
/// `allRunningPIDs` + `executablePath` closures. Spawning real
/// "rooted-in-temp-bundle" processes to exercise the live code path is
/// blocked by Apple Silicon's AMFI (copying `/bin/sleep` drops the signature
/// → unsigned binary refused; hardlinking across the SSV → EPERM), so the
/// live path is left to the existing live-recording E2E.
final class ProcessTreeEnumeratorTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/Applications/Teams.app")

    func testIncludesAllPidsRunningUnderBundle() {
        let inputPids: [pid_t] = [100, 200, 300, 400]
        let paths: [pid_t: String] = [
            100: "/Applications/Teams.app/Contents/MacOS/MSTeams",
            200: "/Applications/Teams.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
            300: "/usr/bin/python3",
            400: "/Applications/Other.app/Contents/MacOS/Other",
        ]
        let found = ProcessTreeEnumerator.pidsRooted(
            in: bundleURL,
            allRunningPIDs: { inputPids },
            executablePath: { paths[$0] },
        )
        XCTAssertEqual(Set(found), [100, 200])
    }

    func testReturnsEmptyWhenNoProcessesUnderBundle() {
        let found = ProcessTreeEnumerator.pidsRooted(
            in: bundleURL,
            allRunningPIDs: { [50, 60] },
            executablePath: { _ in "/usr/bin/python3" },
        )
        XCTAssertEqual(found, [])
    }

    func testReturnsEmptyWhenNoPidsRunning() {
        let found = ProcessTreeEnumerator.pidsRooted(
            in: bundleURL,
            allRunningPIDs: { [] },
            executablePath: { _ in "/never/called" },
        )
        XCTAssertEqual(found, [])
    }

    func testSkipsPidsWithUnknownExecutablePath() {
        // `executablePath` returning nil mirrors `proc_pidpath` refusing
        // (process exited between listpids and pidpath, sandbox barrier).
        let found = ProcessTreeEnumerator.pidsRooted(
            in: bundleURL,
            allRunningPIDs: { [100, 200] },
            executablePath: { pid in
                pid == 100 ? "/Applications/Teams.app/Contents/MacOS/MSTeams" : nil
            },
        )
        XCTAssertEqual(found, [100])
    }

    func testDoesNotMatchSiblingBundleWithCommonPrefix() {
        // The directory-boundary trailing-slash matters: `/Applications/Teams.app`
        // must not match `/Applications/Teams.app.backup/...`.
        let found = ProcessTreeEnumerator.pidsRooted(
            in: bundleURL,
            allRunningPIDs: { [100, 200] },
            executablePath: { pid in
                pid == 100
                    ? "/Applications/Teams.app/Contents/MacOS/MSTeams"
                    : "/Applications/Teams.app.backup/Contents/MacOS/Old"
            },
        )
        XCTAssertEqual(found, [100])
    }

    func testLiveSnapshotIncludesCurrentProcess() {
        // Sanity check that the live helpers actually work — our own xctest
        // PID must show up in the kernel listing and resolve to a non-nil
        // executable path. Doesn't depend on bundle matching.
        let pids = ProcessTreeEnumerator.liveRunningPIDs()
        XCTAssertTrue(pids.contains(getpid()))
        XCTAssertNotNil(ProcessTreeEnumerator.liveExecutablePath(for: getpid()))
    }
}
