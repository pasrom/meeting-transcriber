import CoreAudio
import Darwin
import Foundation

/// Groups a helper process with the application macOS holds *responsible* for it.
///
/// `ProcessTreeEnumerator` groups processes by executable-path prefix, which is
/// right for apps whose helpers live inside their own bundle (Chrome, Electron)
/// and cannot work for Safari: WebKit runs its GPU and WebContent services as
/// XPC under `/System/Library/Frameworks/WebKit.framework`, so rooting at
/// `Safari.app` returns Safari's own processes and never the one producing the
/// call audio.
///
/// Responsibility is the relationship macOS itself uses to attribute a helper's
/// behaviour to an app — it is what TCC consults when a WebKit service touches
/// the microphone. Measured on macOS 26.5:
///
///     pid 2032 [com.apple.WebKit.GPU] -> responsible 707 [com.apple.Safari]
///
/// `responsibility_get_pid_responsible_for_pid` is not in a public header, so it
/// is resolved with `dlsym`; a missing symbol degrades to "no opinion" and the
/// caller keeps its bundle-derived set.
public enum ProcessResponsibility {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// Resolved lazily, and deliberately absent from the App Store build: the
    /// symbol is private API, and shipping the string invites an automated
    /// review flag. Every caller already degrades to the bundle-derived set
    /// when this is nil, so the sandboxed variant simply does not get the
    /// Safari fix — a conscious tradeoff.
    private static let responsibleFn: ResponsibleFn? = {
        #if APPSTORE
            nil
        #else
            guard let handle = dlopen(nil, RTLD_NOW),
                  let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
            else { return nil }
            return unsafeBitCast(sym, to: ResponsibleFn.self)
        #endif
    }()

    /// The app responsible for `pid`, or 0 when unavailable. Identity for a
    /// process that is its own responsible party (a normal app).
    public static func responsiblePID(of pid: pid_t) -> pid_t {
        guard let fn = responsibleFn else { return 0 }
        let owner = fn(pid)
        return owner > 0 ? owner : 0
    }

    /// PIDs that CoreAudio has a process object for — every process that could
    /// meaningfully be tapped, typically a few dozen.
    public static func audioCapablePIDs() -> Set<pid_t> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
        ) == noErr, size > 0 else { return [] }

        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size,
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects,
        ) == noErr else { return [] }

        var pids = Set<pid_t>()
        for object in objects {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain,
            )
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
               pid > 0 {
                pids.insert(pid)
            }
        }
        return pids
    }

    /// Audio-capable processes that macOS attributes to `owner`, including
    /// `owner` itself.
    ///
    /// Iterates the audio-capable set (a few dozen) rather than every live
    /// process (~1900 here), because the intersection is the answer either way
    /// and this asks the kernel for responsibility a few dozen times instead of
    /// a few thousand per recording start.
    ///
    /// `audioCapable` and `responsibleFor` are injection seams so the grouping
    /// is verifiable without real processes.
    public static func audioPIDsResponsible(
        to owner: pid_t,
        audioCapable: () -> Set<pid_t> = audioCapablePIDs,
        responsibleFor: ((pid_t) -> pid_t)? = nil,
    ) -> [pid_t] {
        guard owner > 0 else { return [] }
        // No symbol and no injected lookup means no opinion to offer; returning
        // empty keeps the caller on its bundle-derived set rather than silently
        // widening the tap.
        if responsibleFor == nil, responsibleFn == nil {
            return []
        }
        let lookup = responsibleFor ?? { responsiblePID(of: $0) }
        return audioCapable().filter { $0 == owner || lookup($0) == owner }.sorted()
    }

    /// The PID set an app-audio tap should cover, given the bundle-derived set
    /// the caller already computed.
    ///
    /// Safari's audio is produced by WebKit XPC services that live outside
    /// `Safari.app`, so the bundle-derived set is Safari's main process alone —
    /// which never emits sound. Measured: `App audio tap: 1 PID(s)
    /// [Safari(692)]` while the audio came from `com.apple.WebKit.GPU(21403)`.
    /// The tap was valid and recorded an hour of silence.
    ///
    /// Only widens when `rootPID` is its OWN responsible party, i.e. a normally
    /// launched app. A process started from a shell or script is attributed to
    /// the launcher, and widening on that would tap whatever audio-capable
    /// processes happen to share it — a terminal that played a system sound, a
    /// media tool from the same shell. GUI-launched meeting apps are always
    /// their own responsible party, so the guard costs nothing there.
    public static func tapPIDs(
        rootPID: pid_t,
        bundleDerived: [pid_t],
        responsibleFor: ((pid_t) -> pid_t)? = nil,
        audioCapable: () -> Set<pid_t> = audioCapablePIDs,
    ) -> [pid_t] {
        let lookup = responsibleFor ?? { responsiblePID(of: $0) }
        let owner = lookup(rootPID)
        guard owner != 0, owner == rootPID else { return bundleDerived }
        let byOwner = audioPIDsResponsible(
            to: owner, audioCapable: audioCapable, responsibleFor: responsibleFor,
        )
        guard !byOwner.isEmpty else { return bundleDerived }
        var seen = Set<pid_t>()
        return (bundleDerived + byOwner).filter { seen.insert($0).inserted }
    }
}
