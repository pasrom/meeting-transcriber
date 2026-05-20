import Darwin
import Foundation

/// Enumerates every running PID whose executable lives under a given `.app`
/// bundle directory.
///
/// Electron/WebView2 apps (Teams 2.x, Slack, Discord) render call audio in
/// helper/renderer child processes rather than the shell process the OS sees
/// as the window owner. A single-PID `CATapDescription` on the shell returns
/// silence. Issue #84 reports this for Microsoft Teams 2.x; see
/// `docs/plans/.local/open/2026-05-18-multi-pid-audio-tap-electron-apps.md`.
public enum ProcessTreeEnumerator {
    /// Returns every running PID whose executable path resides under
    /// `bundleURL` (a `.app` bundle). Order is the kernel's listing order,
    /// which is not stable across calls.
    ///
    /// The bundle path is matched as a directory prefix (a trailing slash is
    /// appended) so `/Applications/Foo.app` doesn't accidentally match
    /// `/Applications/FooBar.app`. `resolvingSymlinksInPath()` normalizes
    /// bundles installed under symlinked roots (cheap no-op for the standard
    /// `/Applications/` and `~/Applications/` locations).
    public static func pidsRooted(in bundleURL: URL) -> [pid_t] {
        pidsRooted(
            in: bundleURL,
            allRunningPIDs: liveRunningPIDs,
            executablePath: liveExecutablePath,
        )
    }

    /// Test seam — same matching logic as the public `pidsRooted(in:)` but
    /// driven by injected snapshot/lookup closures. Lets unit tests drive the
    /// kernel-prefix matching without spawning real ad-hoc-unsigned binaries
    /// (which Apple Silicon AMFI kills before `proc_pidpath` can answer).
    static func pidsRooted(
        in bundleURL: URL,
        allRunningPIDs: () -> [pid_t],
        executablePath: (pid_t) -> String?,
    ) -> [pid_t] {
        let bundlePath = bundleURL.resolvingSymlinksInPath().path + "/"
        return allRunningPIDs().filter { pid in
            guard let exePath = executablePath(pid) else { return false }
            return exePath.hasPrefix(bundlePath)
        }
    }

    /// Snapshot of every PID the kernel knows about right now.
    static func liveRunningPIDs() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBufferPointer { buf in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buf.baseAddress,
                Int32(buf.count * MemoryLayout<pid_t>.size),
            )
        }
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        return pids.prefix(count).filter { $0 > 0 }
    }

    /// The kernel's `PROC_PIDPATHINFO_MAXSIZE` (4 × MAXPATHLEN), inlined
    /// because the macro itself isn't bridged into Swift.
    private static let procPidPathMaxSize = 4 * Int(MAXPATHLEN)

    /// `proc_pidpath` for a single PID, or nil if the kernel refuses (process
    /// exited, sandbox boundary, etc.).
    static func liveExecutablePath(for pid: pid_t) -> String? {
        var pathBuf = [CChar](repeating: 0, count: procPidPathMaxSize)
        let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        guard n > 0 else { return nil }
        return String(cString: pathBuf)
    }
}
