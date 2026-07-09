@testable import MeetingTranscriber
import XCTest

/// Unit tests for `DualSourceRecorder.resolveTapPIDs` — the PID-set decision for
/// which processes to tap under a meeting-matched root PID. The injected-closure
/// overload exercises the fallback / passthrough / root-prepend branches without
/// real running processes; the no-arg form covers the real nil-bundle fallback.
@MainActor
final class DualSourceRecorderResolveTapPIDsTests: XCTestCase {
    private let bundle = URL(fileURLWithPath: "/Applications/Teams.app")

    /// `NSRunningApplication(processIdentifier:)` returns nil for a PID that
    /// isn't running — falls back to the single root PID rather than silently
    /// tapping nothing. The safety net for command-line tools, exited processes,
    /// or detection failures. This drives the real (non-injected) path.
    func testResolveTapPIDsFallsBackWhenBundleURLUnavailable() {
        // PID_MAX on macOS is 99999. Pick something deliberately past it.
        let bogusPID: pid_t = 999_999
        let pids = DualSourceRecorder.resolveTapPIDs(rootPID: bogusPID)
        XCTAssertEqual(pids, [bogusPID])
    }

    func testResolveTapPIDsFallsBackToRootWhenNoBundleURL() {
        // nil bundle URL (command-line tool / exited process) → just the root.
        let pids = DualSourceRecorder.resolveTapPIDs(rootPID: 42, bundleURL: nil) { _ in [7, 8, 9] }
        XCTAssertEqual(pids, [42], "no bundle URL must fall back to the root PID alone")
    }

    func testResolveTapPIDsFallsBackToRootWhenEnumerationEmpty() {
        // Bundle resolved but no PIDs found under it → the root alone, not [].
        let pids = DualSourceRecorder.resolveTapPIDs(rootPID: 42, bundleURL: bundle) { _ in [] }
        XCTAssertEqual(pids, [42], "empty enumeration must fall back to the root PID, never an empty tap set")
    }

    func testResolveTapPIDsPassesEnumerationThroughWhenItAlreadyIncludesRoot() {
        // Enumeration already contains the root → use it verbatim (no reordering).
        let pids = DualSourceRecorder.resolveTapPIDs(rootPID: 42, bundleURL: bundle) { _ in [100, 42, 200] }
        XCTAssertEqual(pids, [100, 42, 200], "when enumeration already includes the root, order is preserved as-is")
    }

    func testResolveTapPIDsPrependsRootWhenEnumerationMissesIt() {
        // Enumeration missed the root → prepend it. Order is load-bearing: the
        // root must come FIRST because the aggregate device's cosmetic name tag
        // is taken from the first PID (#84, Electron helper children).
        let pids = DualSourceRecorder.resolveTapPIDs(rootPID: 42, bundleURL: bundle) { _ in [100, 200] }
        XCTAssertEqual(pids, [42, 100, 200], "the root must be prepended (first), not appended")
    }
}
