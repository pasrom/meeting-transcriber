import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "ProcessArguments")

/// Reads another process's launch arguments, which is how a Chromium helper
/// says what it is for (`--type=utility --utility-sub-type=...`). Nothing in
/// the executable path or the bundle id tells the audio service apart from
/// the video-capture service: both run as the plain `<Browser> Helper`.
enum ProcessArguments {
    /// `kern.argmax`, the upper bound on what `KERN_PROCARGS2` returns.
    /// Constant for the boot, so read once.
    private static let argmax: Int = {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return 0 }
        return Int(argmax)
    }()

    /// `argv` of `pid`, or empty when the kernel will not say (another user's
    /// process, a process that exited, a sandbox that denies the sysctl). A
    /// running process always has at least `argv[0]`, so empty is "no
    /// opinion" for every caller, never "no arguments". A refusal is logged
    /// with its errno, because a sandboxed build that is refused every time
    /// silently keeps the full helper set, and the log is the only place that
    /// shows it.
    static func live(_ pid: pid_t) -> [String] {
        guard argmax > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: argmax)
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard status == 0 else {
            let code = errno
            logger.info("Arguments of pid \(pid, privacy: .public) unreadable (errno \(code, privacy: .public)); treated as no opinion")
            return []
        }
        return parse(procargs2: Array(buffer.prefix(size)))
    }

    /// Decodes the `KERN_PROCARGS2` layout: a native-endian `Int32` argument
    /// count, the executable path, NUL padding, then `argc` NUL-terminated
    /// arguments (the environment follows and is not read). Returns empty for
    /// a buffer that does not carry `argc` complete arguments, so a truncated
    /// read cannot pass off a partial argument as a whole one.
    ///
    /// Known limit of the layout, shared with `ps`: an empty `argv[0]` is one
    /// more NUL in the padding, so for such a process the arguments shift by
    /// one and the last one read is the first environment entry. Environment
    /// entries are `KEY=value`, and no key starts with `--type`, so the role
    /// a caller derives is unaffected.
    static func parse(procargs2 bytes: [UInt8]) -> [String] {
        let countWidth = MemoryLayout<Int32>.size
        guard bytes.count > countWidth else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }

        var cursor = countWidth
        // The executable path, then the padding after it.
        while cursor < bytes.count, bytes[cursor] != 0 {
            cursor += 1
        }
        while cursor < bytes.count, bytes[cursor] == 0 {
            cursor += 1
        }

        var arguments: [String] = []
        while arguments.count < Int(argc) {
            guard let end = bytes[cursor...].firstIndex(of: 0),
                  let argument = String(bytes: bytes[cursor ..< end], encoding: .utf8)
            else { return [] }
            arguments.append(argument)
            cursor = end + 1
        }
        return arguments
    }
}
