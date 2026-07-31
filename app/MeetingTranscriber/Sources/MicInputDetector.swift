import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "MicInputDetector")

/// Detects active calls by watching which processes are capturing microphone
/// input, via the Core Audio process-object API (macOS 14.2+, same API family
/// the recorder's process tap uses — no extra entitlement, no polling of
/// window titles).
///
/// Complements `PowerAssertionDetector` for call apps whose in-call power
/// assertions are absent, unnamed, or undocumented (WeChat, Tencent Meeting,
/// FaceTime, WhatsApp): a call ALWAYS captures the mic, so
/// `kAudioProcessPropertyIsRunningInput` flipping true on a watched bundle ID
/// is a reliable signal.
///
/// Precision is deliberately traded for coverage, and the cost is real: any
/// watched app holding the mic across `confirmationCount` polls starts a
/// recording, so a WeChat or WhatsApp voice message longer than roughly
/// `pollInterval * confirmationCount` (about 6 s at the defaults) looks like a
/// call. There is no minimum-duration filter downstream to catch that. What
/// limits the blast radius today: every one of these apps is off by default,
/// detection needs N consecutive polls, and a 5 s cooldown follows a reset.
/// `AppMeetingPattern.requiresRecordingConsent` would be the stronger lever,
/// as the browser channel uses it, but it is not enabled for these patterns.
@Observable
class MicInputDetector: MeetingDetecting {
    /// A call app watched by bundle ID.
    struct MicPattern {
        let appName: String
        /// Bundle IDs whose audio processes count as this app (main app +
        /// helper/conference-daemon processes).
        let bundleIDs: [String]
    }

    static let defaultPatterns: [MicPattern] = [
        // WeChat calls run in the main app process. (Its sandboxed helpers
        // `.IPCHelper`, `.MiniProgram` and `.WeChatMacShare` are deliberately
        // not listed: a mini program recording audio is not a call.)
        MicPattern(appName: "WeChat", bundleIDs: ["com.tencent.xinWeChat"]),
        // Two separate builds: `com.tencent.meeting` is 腾讯会议, and the
        // international VooV Meeting build is `com.tencent.tencentmeeting`
        // (both confirmed from the Homebrew casks' quit/zap identifiers).
        // `com.tencent.wemeet` is kept as unverified insurance: the only
        // wemeet-namespaced artifact found is a `.FileDelta` helper container,
        // so it may never match a main app process.
        MicPattern(
            appName: "Tencent Meeting",
            bundleIDs: ["com.tencent.meeting", "com.tencent.tencentmeeting", "com.tencent.wemeet"],
        ),
        // Measured on macOS 26.5.2 during a native FaceTime audio call: the
        // owner is `com.apple.avconferenced`, and `com.apple.FaceTime` never
        // reports input at all. The app bundle is kept in case another macOS
        // version attributes it differently. Two consequences of the owner
        // being a daemon: the reported PID is the daemon's, so the recorder
        // taps `avconferenced` (correct, the call audio lives there) while the
        // window-title matcher finds no window and falls back to the
        // placeholder, and ParticipantReader has no window to read. Note also
        // that `avconferenced` serves AV conferencing in general, not FaceTime
        // alone. A FaceTime *link* joined in a browser is owned by
        // `com.apple.WebKit.GPU` instead and is not covered here; that case
        // belongs to the browser detection channel.
        MicPattern(appName: "FaceTime", bundleIDs: ["com.apple.FaceTime", "com.apple.avconferenced"]),
        MicPattern(appName: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp"]),
    ]

    /// The `defaultPatterns` subset selected by the user's "Apps to Watch"
    /// toggles — same contract as `PowerAssertionDetector.patterns(watching:)`.
    static func patterns(watching watchedAppNames: [String]) -> [MicPattern] {
        let watched = Set(watchedAppNames)
        return defaultPatterns.filter { watched.contains($0.appName) }
    }

    private let patterns: [MicPattern]
    private let confirmationCount: Int
    private var consecutiveHits: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]
    private let cooldownDuration: TimeInterval = 5
    /// Bundle IDs already logged as running-input-but-unmatched, so a live
    /// call on an unlisted bundle names itself once per session in the log.
    private var loggedMissBundles: Set<String> = []

    /// Injectable process snapshot for tests. Production reads Core Audio.
    var processProvider: () -> [AudioProcessSnapshot] = MicInputDetector.systemAudioProcesses

    /// Injectable window list for title lookup, mirroring PowerAssertionDetector.
    var windowListProvider: () -> [[String: Any]] = MeetingDetector.systemWindowList

    private let matchers: [String: MeetingTitleMatcher]

    struct AudioProcessSnapshot {
        let bundleID: String
        let pid: pid_t
        let isRunningInput: Bool
    }

    init(
        patterns: [MicPattern] = MicInputDetector.defaultPatterns,
        confirmationCount: Int = 2,
    ) {
        self.patterns = patterns
        self.confirmationCount = confirmationCount
        matchers = patterns.reduce(into: [:]) { dict, pattern in
            guard let meetingPattern = AppMeetingPattern.forAppName(pattern.appName) else {
                logger.error(
                    "No AppMeetingPattern for watched app \(pattern.appName, privacy: .public); its meeting titles fall back to the placeholder",
                )
                return
            }
            dict[pattern.appName] = MeetingTitleMatcher(pattern: meetingPattern)
        }
    }

    func checkOnce() -> DetectedMeeting? {
        // All four toggles default to off, so most installs run this detector
        // with an empty pattern set. Skip the whole round then: no Core Audio
        // enumeration every poll, and no diagnostic naming every mic-using
        // bundle on machines that never opted into this channel.
        guard !patterns.isEmpty else { return nil }

        let processes = processProvider()
        var hitsThisRound: Set<String> = []
        var firstMatch: [String: pid_t] = [:]

        for process in processes where process.isRunningInput {
            guard let pattern = patterns.first(where: { $0.bundleIDs.contains(process.bundleID) }) else {
                logUnmatchedRunningInput(bundleID: process.bundleID)
                continue
            }
            if let until = cooldownUntil[pattern.appName], Date() < until { continue }
            guard !hitsThisRound.contains(pattern.appName) else { continue }
            hitsThisRound.insert(pattern.appName)
            firstMatch[pattern.appName] = process.pid
            consecutiveHits[pattern.appName, default: 0] += 1
        }

        for (appName, hits) in consecutiveHits {
            if hits >= confirmationCount, let pid = firstMatch[appName] {
                let meetingPattern = AppMeetingPattern.forAppName(appName) ?? AppMeetingPattern(
                    appName: appName,
                    ownerNames: [appName],
                    meetingPatterns: [],
                )
                let title = matchers[appName]?.selectWindowTitle(from: windowListProvider())
                    ?? PowerAssertionDetector.placeholderTitle(appName: appName)
                return DetectedMeeting(
                    pattern: meetingPattern,
                    windowTitle: title,
                    ownerName: appName,
                    windowPID: pid,
                )
            }
        }

        for appName in consecutiveHits.keys where !hitsThisRound.contains(appName) {
            consecutiveHits[appName] = 0
        }

        return nil
    }

    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        guard let pattern = patterns.first(where: { $0.appName == meeting.pattern.appName }) else {
            return false
        }
        return processProvider().contains { $0.isRunningInput && pattern.bundleIDs.contains($0.bundleID) }
    }

    func reset(appName: String? = nil) {
        consecutiveHits.removeAll()
        if let appName {
            cooldownUntil[appName] = Date().addingTimeInterval(cooldownDuration)
        }
    }

    // MARK: - Diagnostics

    /// Log, once per distinct bundle, that a process is capturing mic input but
    /// matched no watched pattern — the discovery channel for call apps whose
    /// real audio-owning bundle differs from the documented one (FaceTime's
    /// conference daemon, Electron helper bundles, …). App-generated metadata
    /// only, logged `.public` so a diagnostic export names the actual bundle.
    private func logUnmatchedRunningInput(bundleID: String) {
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return }
        guard loggedMissBundles.insert(bundleID).inserted else { return }
        logger.info("Process with bundle \(bundleID, privacy: .public) is capturing mic input but matches no watched call app.")
    }

    // MARK: - Core Audio

    /// Snapshot every Core Audio process object: bundle ID, PID, and whether it
    /// is currently running audio INPUT (capturing a microphone).
    static func systemAudioProcesses() -> [AudioProcessSnapshot] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return [] }

        var objectIDs = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objectIDs) == noErr
        else { return [] }

        return objectIDs.compactMap { objectID in
            // A process without a bundle (a plain CLI tool such as `afplay`)
            // answers noErr with an EMPTY string rather than failing, so the
            // optional alone does not filter it. Such an entry can never match
            // a watched pattern; drop it here so the snapshot list keeps its
            // "every entry identifies an app" invariant.
            guard let bundleID = stringProperty(objectID, selector: kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty
            else {
                return nil
            }
            let pid = pid_t(int32Property(objectID, selector: kAudioProcessPropertyPID) ?? -1)
            let running = (uint32Property(objectID, selector: kAudioProcessPropertyIsRunningInput) ?? 0) != 0
            return AudioProcessSnapshot(bundleID: bundleID, pid: pid, isRunningInput: running)
        }
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
    }

    private static func stringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func uint32Property(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr else { return nil }
        return value
    }

    private static func int32Property(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Int32? {
        var address = propertyAddress(selector)
        var dataSize = UInt32(MemoryLayout<Int32>.size)
        var value: Int32 = 0
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr else { return nil }
        return value
    }
}

/// Runs several detection strategies as one detector: first confirmed hit
/// wins; a meeting stays alive while ANY strategy still sees it (each
/// strategy returns false for apps outside its own pattern set, so the OR is
/// exact). Lets the assertion-based and mic-input-based channels coexist
/// without WatchLoop knowing there are two.
final class CompositeMeetingDetector: MeetingDetecting {
    private let detectors: [any MeetingDetecting]

    init(_ detectors: [any MeetingDetecting]) {
        self.detectors = detectors
    }

    func checkOnce() -> DetectedMeeting? {
        for detector in detectors {
            if let meeting = detector.checkOnce() {
                return meeting
            }
        }
        return nil
    }

    func isMeetingActive(_ meeting: DetectedMeeting) -> Bool {
        detectors.contains { $0.isMeetingActive(meeting) }
    }

    func reset(appName: String?) {
        for detector in detectors {
            detector.reset(appName: appName)
        }
    }
}
