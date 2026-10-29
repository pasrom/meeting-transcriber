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
        resolveTapPIDs(
            rootPID: rootPID,
            bundleURL: NSRunningApplication(processIdentifier: rootPID)?.bundleURL,
            enumerate: ProcessTreeEnumerator.pidsRooted(in:),
            // Safari's audio runs in WebKit XPC outside Safari.app — see ProcessResponsibility.tapPIDs.
            widen: { ProcessResponsibility.tapPIDs(rootPID: rootPID, bundleDerived: $0) },
            select: ChromiumHelperFilter.audioRelevantPIDs,
        )
    }

    /// Test seam — same PID-set decision as `resolveTapPIDs(rootPID:)` but with
    /// the running-app bundle lookup, child-PID enumeration, the responsibility
    /// widening and the helper selection injected, so the empty-enumeration
    /// fallback, the already-includes-root passthrough, the load-bearing
    /// root-prepend ordering (aggregate device name tag; #84) and the
    /// widen-then-select order are unit-testable without real running processes.
    ///
    /// `select` runs last on purpose: `widen` attributes a Chromium helper to its
    /// browser just like the bundle walk does, so a helper dropped before the
    /// widening would be re-added by it (issue #791, `ChromiumHelperFilter`).
    static func resolveTapPIDs(
        rootPID: pid_t,
        bundleURL: URL?,
        enumerate: (URL) -> [pid_t],
        widen: ([pid_t]) -> [pid_t] = \.self,
        select: ([pid_t]) -> [pid_t] = \.self,
    ) -> [pid_t] {
        guard let bundleURL else { return [rootPID] }
        let enumerated = enumerate(bundleURL)
        // Empty `enumerated` needs no guard: it falls through to `[rootPID] + []`, the root alone.
        let bundleDerived = enumerated.contains(rootPID) ? enumerated : [rootPID] + enumerated
        return select(widen(bundleDerived))
    }
}
