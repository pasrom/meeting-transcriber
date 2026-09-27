import AppKit
import AudioTapLib
import Foundation

/// Which processes a recording taps, split out of `DualSourceRecorder.swift`
/// to keep that file under the line cap. A clean seam: both functions are
/// static, touch no recorder state, and are tested on their own.
extension DualSourceRecorder {
    /// Resolve the PID set to tap for a meeting-matched root PID.
    ///
    /// Returns `[rootPID]` alone when the running-application bundle URL is
    /// unavailable (command-line tool, detached process) or enumeration
    /// finds no PIDs under it. Otherwise returns every PID under the bundle,
    /// prepending the root if enumeration somehow missed it — order matters
    /// for the aggregate device's cosmetic name tag (root first).
    static func resolveTapPIDs(rootPID: pid_t) -> [pid_t] {
        // Safari's audio runs in WebKit XPC outside Safari.app — see ProcessResponsibility.tapPIDs.
        ProcessResponsibility.tapPIDs(rootPID: rootPID, bundleDerived: resolveTapPIDs(
            rootPID: rootPID,
            bundleURL: NSRunningApplication(processIdentifier: rootPID)?.bundleURL,
            enumerate: ProcessTreeEnumerator.pidsRooted(in:),
        ))
    }

    /// Test seam — same PID-set decision as `resolveTapPIDs(rootPID:)` but with
    /// the running-app bundle lookup + child-PID enumeration injected, so the
    /// empty-enumeration fallback, the already-includes-root passthrough, and the
    /// load-bearing root-prepend ordering (aggregate device name tag; #84) are
    /// unit-testable without real running processes.
    static func resolveTapPIDs(
        rootPID: pid_t,
        bundleURL: URL?,
        enumerate: (URL) -> [pid_t],
    ) -> [pid_t] {
        guard let bundleURL else { return [rootPID] }
        let enumerated = enumerate(bundleURL)
        // Empty `enumerated` needs no guard: it falls through to `[rootPID] + []`, the root alone.
        return enumerated.contains(rootPID) ? enumerated : [rootPID] + enumerated
    }
}
